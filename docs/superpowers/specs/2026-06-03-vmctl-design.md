# vmctl — Bhyve VM management — Design

**Date:** 2026-06-03
**Status:** Approved design, pre-implementation

## Summary

`vmctl` is a pure-Ruby (stdlib + FreeBSD base system only, no gems) CLI for
managing [bhyve](https://wiki.freebsd.org/bhyve) virtual machines that use the
`bhyve_config` (`-k`) configuration format with netgraph networking.

It is a *management layer* on top of bhyve, not a replacement for it. bhyve
already does config templating via shared `.conf` files plus `-o key=value`
overrides:

```sh
bhyve -k ../configs/pod.conf -o network=labs_vlan50 -o link=8 pod34
```

vmctl removes the manual toil around that: knowing the next free ID, which
bridge to use, which shared config to apply, and keeping VMs running across
guest reboots. Shared `.conf` templates stay **pristine and external** — vmctl
reconstructs the exact `bhyve -k <template> -o …` invocation from a central
inventory; it never rewrites your templates or invents a new config format.

It follows the conventions established in the sibling `zfsreplicate` project:
`bin/<tool>` shim → `lib/<tool>/{cli,config,executor,log,version}.rb`,
Struct-based config, `OptionParser` CLI, an Open3 `Executor` as the sole
shell-out boundary, and `test/` with a `run_all.rb` minitest runner.

## Goals (priority order)

1. **Lifecycle** — `start` / `stop` / `restart` / `status` / `console`, wrapping
   `bhyve` + `bhyvectl` and a supervisor loop that handles the reboot-vs-poweroff
   exit codes. (Most painful today.)
2. **Inventory** — a central registry so `vmctl start pod34` knows the VM's
   `network`, `link`, `mac`, and template without hand-passing `-o` flags.
3. **Provisioning** — `create` new VMs: allocate IDs, create the per-VM ZFS
   dataset and raw image files, and build cloud-init seed ISOs.
4. **Netgraph** — *validate* (not create) the named bridge before start, and own
   allocation of the unique `link` hook.

## Non-goals

- **Bridge / host-network management.** Netgraph bridges (`ng_bridge` + `ng_ether`
  uplinks, host IPs, routes, MTU, promisc/autosrc) are shared host infrastructure
  serving jails too, created by an existing `netgraph_setup` rc script. vmctl
  only verifies a named bridge exists; it never mutates topology.
- **A new config format.** vmctl drives the existing `bhyve_config` format; it
  does not parse or replace `.conf` templates beyond validating referenced disk
  paths.
- **ZFS volumes (zvols).** Disks are raw image files (measurably faster than
  zvols in the user's testing).

## Architecture

### Through-line

The central inventory stores, per VM, the set of `-o` override values plus a
pointer to a shared template. At `start`, `vm.rb` reconstructs:

```
bhyve -k <template> -o network=<net> -o link=<n> [-o mac=<mac>] <name>
```

The inventory is the single source of truth. There is no per-VM rendered config
file and no separate allocation counter — nothing can drift out of sync.

### Inventory model

One YAML file, vmctl-owned, default `/usr/local/etc/vmctl/inventory.yml`
(override with `-c`). Written atomically (temp file + rename) so a crash can't
corrupt it.

```yaml
defaults:
  config_dir: /bhyve/configs    # where shared .conf templates live
  vm_root: /bhyve               # <vm_root>/<name>/ is the per-VM dataset mountpoint
  zpool: tank/bhyve             # parent dataset; <zpool>/<name> is each VM's dataset
  template: pod.conf            # default shared config when a VM omits one
  link_base: 10                 # lowest link the allocator will assign (0-9 reserved
                                # for manual testing / one-offs)

vms:
  pod34:
    config: pod.conf            # -k template (relative to config_dir)
    network: labs_vlan50        # -o network=
    link: 10                    # -o link= ; globally unique; also /dev/nmdm10A
    mac: null                   # -o mac= ; null → let bhyve auto-generate
    autostart: true             # start at host boot via the rc.d shim
    disks:                      # raw images vmctl creates/tracks
      - { file: pod34-root.raw, size: 20G, from: base-14.raw }  # cloned from golden
      - { file: pod34-zfs.raw,  size: 100G }                    # blank
    cloud_init:                 # optional; omit for non-cloud-init VMs
      user_data: pod34-user-data.yml   # rendered → cidata ISO, attached as CD
```

Notes:
- `link` is globally unique because it is *both* the netgraph peerhook
  (`peerhook=link%(link)`) and the nmdm console index (`/dev/nmdm%(link)A`).
- `disks` supply **sizes** and optional golden `from:` source; the template
  defines disk **topology** (which nvme slots, the `%(name)-root.raw` paths).
  vmctl validates the two agree at create time.
- `mac` is optional, matching the commented-out `#…mac=%(mac)` convention today.
  Default is bhyve's auto-MAC; a pinned MAC stays stable across `import`/move.

### Lifecycle & supervisor

`vmctl start <name>`:

1. **Pre-flight** (fail fast, clear errors): inventory has the VM; template
   exists; the `network` bridge exists (`ngctl info <net>:`); disks exist; no
   live pidfile and no stale `/dev/vmm/<name>` device (else "already running").
2. **Fork + detach** a supervisor; write `/var/run/vmctl/<name>.pid` (the
   supervisor's pid); redirect its output to `/var/log/vmctl/<name>.log`. `start`
   returns immediately.
3. **Supervisor loop:**
   ```ruby
   loop do
     status = run("bhyve -k <tmpl> -o network=.. -o link=.. <name>")
     run("bhyvectl --destroy --vm=<name>")   # always clean the vmm device
     break unless reboot?(status)            # 0=reboot → relaunch; else stop
   end
   # remove pidfile on exit
   ```
   bhyve exit codes: `0` = reboot/reset → relaunch; `1` = poweroff, `2` = halt,
   `3` = triple-fault → stop. `destroy_on_poweroff=true` in the template is
   belt-and-suspenders alongside the explicit `--destroy`.

`vmctl stop <name>` — read pidfile, trigger a graceful ACPI poweroff
(`bhyvectl --force-poweroff`), wait up to a timeout, then escalate to
`--destroy` and kill the supervisor. `--force` skips straight to destroy.

`vmctl restart <name>` — graceful stop then start.

`vmctl status [name]` — read pidfiles + check `/dev/vmm/<name>`; print per-VM
`running/stopped`, pid, uptime, link, network.

`vmctl console <name>` — attach to `/dev/nmdm<link>B` via `cu -l` (the `A` side
is the guest).

The supervisor is plain Ruby (`fork` / `Process.detach`, stdlib only) — no
`daemon(8)` — for exact control over the reboot/destroy logic.

**Host-boot autostart:** vmctl emits one small rc.d script
(`/usr/local/etc/rc.d/vmctl`) that runs `vmctl start --all` at boot, starting
only VMs with `autostart: true`. One shim for the whole fleet keeps the
inventory the single source of truth.

### create / import / destroy

`vmctl create <name> [options]`:

1. **Allocate** — lowest free `link` ≥ `link_base` across all VMs; resolve
   `network` (`--network`, else error); resolve `config` (`--config`, else
   `defaults.template`); optionally pin `mac` (`--mac` or generated).
2. **Validate** — bridge exists; template exists and its disk-path references
   line up with the requested `disks`; `name`/`link` not already taken.
3. **Provision** —
   - `zfs create <zpool>/<name>` (own dataset → independent send/recv).
   - Each disk: if `from:` given, copy the golden raw then grow to `size`; else
     create a sparse raw of `size` (`truncate -s`). Files land in
     `<vm_root>/<name>/`.
   - If `--cloud-init <user-data>`: render meta-data (instance-id, hostname) +
     user-data into a seed dir; build `cidata.iso` via
     `makefs -t cd9660 -o rockridge,label=cidata`; drop it in the dataset. The
     template (or a cloud-init variant) must carry an AHCI-CD slot; vmctl
     validates that.
4. **Register** — atomic write of the new entry into `inventory.yml`.
5. **Not auto-started** — `create` defines + provisions only. `--start` to boot
   immediately.

Most creates reduce to `vmctl create pod35 --network labs_vlan50` thanks to the
`defaults:` block.

`vmctl import <name> [options]` — for VMs that arrived via `zfs recv`:
- Disks/dataset already exist; import does **not** provision them.
- Allocates a **fresh** `link` and resolves `network`/`config` on *this* host
  (the whole point — no inherited IDs to collide).
- Scans `<vm_root>/<name>/` for `*.raw` to populate `disks` (sizes from the
  files), then writes the inventory entry.

`vmctl destroy <name>` (verb mirrors bhyve/bhyvectl) — remove from inventory;
`--purge` also `zfs destroy`s the dataset. Refuses if running. Confirms unless
`--yes`.

### Allocation & netgraph validation

A single `Allocator` holds the rules (unit-testable in one place):
- **`link`** — lowest free integer ≥ `link_base` (default 10) across all
  inventory `link` values. Used by both `create` and `import`.
- **`mac`** — when pinned, generated from a locally-administered OUI
  (e.g. `58:9c:fc:xx:xx:xx`) deterministically seeded by name → stable across
  moves. Default unset → bhyve auto-MAC.
- **Bridge validation** — `ngctl info <network>:` before `create`/`start`; clear
  error ("bridge `labs_vlan50` not found — is `netgraph_setup` running?") on
  failure. vmctl never mutates bridge topology.
- **Liveness** — `start` confirms no stale `/dev/vmm/<name>` and no live console
  holder, so a half-dead VM yields a clear message rather than a cryptic bhyve
  failure.

## Module layout

```
vmctl/
  bin/vmctl                     # $LOAD_PATH shim → VMCtl::CLI.run(ARGV)
  lib/vmctl/
    cli.rb                      # OptionParser, subcommand dispatch, usage
    config.rb                   # load/parse/atomic-write inventory.yml; Struct VMs
    executor.rb                 # Open3 wrapper (run/capture), dry-run aware [ported]
    log.rb                      # Logger setup                              [ported]
    version.rb
    allocator.rb                # lowest-free link (base 10), mac gen, collisions
    netgraph.rb                 # ngctl bridge existence + hook queries (read-only)
    supervisor.rb               # fork/detach loop, pidfile, bhyve+bhyvectl, exit-codes
    vm.rb                       # one VM: render bhyve argv, paths, vmm/pid state
    provisioner.rb              # zfs create, raw image create/clone, truncate/grow
    cloudinit.rb                # render meta-data/user-data → makefs cidata.iso
    commands/                   # thin per-verb handlers, one file each
      start.rb stop.rb restart.rb status.rb console.rb
      create.rb import.rb destroy.rb list.rb
  test/
    run_all.rb                  # same runner pattern as zfsreplicate
    test_*.rb                   # minitest, no gems
  docs/superpowers/specs/…
  README.md  Gemfile  .ruby-version(3.3)  .gitignore  LICENSE
  .github/workflows/test.yml
```

**Principles carried from zfsreplicate:**
- `Executor` is the *only* thing that shells out — every `bhyve` / `bhyvectl` /
  `ngctl` / `zfs` / `makefs` / `cu` call goes through it, so it is
  `--dry-run`-aware and the rest of the code is testable via an injected fake.
- Commands are thin: parse/validate args, then delegate to domain objects.
- `vm.rb` owns argv rendering — the single place that turns an inventory entry
  into `bhyve -k … -o …`.

## Testing

No gems; minitest + `test/run_all.rb`, as in zfsreplicate.

- **Pure-logic units, fully tested:** allocator (lowest-free, base 10,
  collisions), argv rendering, config round-trip + atomic write, cloud-init
  seed-dir contents, supervisor exit-code → action mapping.
- **Shell-out boundaries:** a **fake executor** asserts exact commands
  (e.g. start renders
  `bhyve -k pod.conf -o network=labs_vlan50 -o link=10 pod34`).
- **`--dry-run`** on every mutating command prints commands without running them
  — both a safety/inspection feature and a test surface.

## CLI surface

```
vmctl [options] <command> [args]

Commands:
  start [name|--all]    Start VM(s) under a supervisor.
  stop  [name|--all]    Graceful ACPI poweroff, then destroy on timeout.
  restart <name>        Graceful stop then start.
  status [name]         Running/stopped, pid, uptime, link, network.
  console <name>        Attach to the VM's nmdm console.
  create <name>         Allocate + provision a new VM.
  import <name>         Adopt existing (zfs-recv'd) disks as a new local VM.
  destroy <name>        Remove from inventory (--purge also zfs-destroys dataset).
  list                  List configured VMs.
  help                  Show this message.

Options:
  -c, --config FILE     Inventory file (default: /usr/local/etc/vmctl/inventory.yml)
  -v, --verbose         Verbose output
  -n, --dry-run         Print actions without executing
  -V, --version         Print version and exit

Per-command (selected):
  create  --network NET --config TMPL --mac MAC --cloud-init USER_DATA
          --disk file:size[:from] (repeatable) --start
  import  --network NET --config TMPL
  stop    --force
  destroy --purge --yes
```
