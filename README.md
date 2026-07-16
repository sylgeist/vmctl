# vmctl

A pure-Ruby CLI for managing [bhyve](https://wiki.freebsd.org/bhyve) VMs that use
the `bhyve_config` (`-k`) format with netgraph networking. No gems — Ruby stdlib
and FreeBSD base system tools only.

vmctl is a management layer on top of bhyve, not a replacement for it. bhyve
already templates configs via shared `.conf` files plus `-o key=value`
overrides; vmctl removes the toil around that — knowing the next free ID, which
bridge to use, which shared config to apply, and keeping VMs running across
guest reboots. Your shared `.conf` templates stay pristine and external.

## Requirements

- Ruby >= 4.0
- FreeBSD with `bhyve`, `bhyvectl`, `ngctl`, `cu` in PATH
- Netgraph bridges created out of band (e.g. a `netgraph_setup` rc script)

## Inventory

vmctl reads one YAML inventory (default `/usr/local/etc/vmctl/inventory.yml`,
override with `-c`):

```yaml
defaults:
  config_dir: /bhyve/configs   # shared .conf templates
  vm_root: /bhyve              # <vm_root>/<name>/ holds each VM's images
  zpool: tank/bhyve            # parent dataset
  template: pod.conf           # default shared config
  link_base: 10                # lowest auto-assigned link (0-9 reserved)
  run_dir: /var/run/vmctl      # supervisor pidfiles
  log_dir: /var/log/vmctl      # per-VM bhyve output
  cpus: 1                      # default vCPU count; per-VM override with `cpus:`
  memory: 1G                   # default memory (Sizes format: 1G/512M); per-VM override with `memory:`

vms:
  pod34:
    config: pod.conf
    network: labs_vlan50       # netgraph bridge name
    link: 10                   # unique; netgraph peerhook AND /dev/nmdm10
    mac: null                  # null → bhyve auto-MAC
    autostart: true
    disks:
      - { file: pod34-root.raw, size: 20G }
```

At `start`, vmctl renders an ephemeral config from the template and invocation supervisory management:

```sh
bhyve -k /var/run/vmctl/pod34.conf pod34
```

and supervises it: when the guest reboots, bhyve exits and vmctl relaunches it;
when it powers off, vmctl runs `bhyvectl --destroy` and stops.

A complete, self-consistent example set lives in [`examples/`](examples/):

- [`inventory.yml`](examples/inventory.yml) — annotated inventory (a two-disk
  autostart VM, a cloud-init VM, and a commented-out installer-ISO VM)
- [`pod.conf`](examples/pod.conf) — shared bhyve_config template; declares only
  OS-core settings (bootrom, hostbridge, rng, lpc console, acpi flags)
- [`user-data.yml`](examples/user-data.yml) — minimal NoCloud user-data

## Usage

```
vmctl [options] <command> [args]

  start [name|--all]   Start VM(s) under a supervisor.
  stop  [name|--all]   Graceful poweroff (TERM); --force destroys immediately.
  restart <name>       Graceful stop then start.
  status [name]        Running/stopped, pid, network, link.
  console <name>       Attach to the VM's nmdm console (cu); ~. to detach.
  create <name>        Allocate + provision a new VM (--network NET).
  import <name>        Adopt an existing (zfs-recv'd) VM's disks (--network NET).
  clone <src> <name>   Clone an existing VM into a new independent copy.
  destroy <name>       Remove a VM (--purge also zfs-destroys its dataset).
  list                 List configured VMs.

  -c, --config FILE    Inventory file (default /usr/local/etc/vmctl/inventory.yml)
  -v, --verbose        Verbose output
  -n, --dry-run        Print actions without executing
  -V, --version        Print version and exit
```

## Boot integration

Install the rc.d shim and enable it:

```sh
cp rc/vmctl /usr/local/etc/rc.d/vmctl && chmod +x /usr/local/etc/rc.d/vmctl
sysrc vmctl_enable=YES
```

At boot it runs `vmctl start --all`, starting only VMs with `autostart: true`.

## Provisioning

`create` lays down a per-VM ZFS dataset and raw image file(s), and (with
`--cloud-init FILE`) a NoCloud seed ISO. Defaults come from the `defaults:`
block (`image_dir`, `root_size`, `root_from`):

    vmctl create pod35   --network labs_vlan50                                  # single root disk from the default golden image
    vmctl create db1     --network labs_vlan50 --disk data:200G                 # add a blank data disk
    vmctl create web1    --network labs_vlan50 --cloud-init ./web-userdata.yml --start
    vmctl create pod36   --network labs_vlan50 --iso /bhyve/isos/freebsd-14.3.iso --start
    vmctl create db2     --network labs_vlan50 --cpus 4 --memory 8G                    # override cpus/memory defaults

vmctl generates cpus/memory and all device attachments from the inventory —
templates declare OS-core settings only. There is no template/iso pairing
requirement:

- **CPU** (`cpus`) — generated from the VM's `cpus:` field, falling back to
  `defaults.cpus` (1 if unset). Override at creation with `--cpus N`, or
  change it later with `vmctl set <name> --cpus N`.
- **Memory** (`memory.size`) — generated from the VM's `memory:` field
  (`Sizes` format, e.g. `1G`/`512M`), falling back to `defaults.memory` (1G if
  unset). Override at creation with `--memory SIZE`, or change it later with
  `vmctl set <name> --memory SIZE`.
- **Disks** (`pci.0.3.N`, max 8) — generated from the VM's `disks:` list.
- **NICs** (`pci.0.4.N`) — generated from `network`/`link`/`mac` + `networks:`.
- **Installer ISO** (`pci.0.5.0`) — generated when `iso:` is present; the ISO is
  referenced in place (never copied) and stays attached until you remove `iso:`.
  With UEFI this is harmless once the installed disk boots first.
- **Cloud-init seed ISO** (`pci.0.6.0`) — generated when `cloud_init:` is present;
  vmctl builds a NoCloud ISO (label "cidata") from the `user_data:` template and
  optional `vars:`.
- **Graphics console** (`pci.0.7.0`, `pci.0.8.0`) — generated when `graphics: true`
  is set on a VM: a bhyve `fbuf` VNC console plus an `xhci`+`tablet` USB pointer,
  giving a complete graphical console. Default is `false`. The VNC port is
  `vnc_base + link` (`defaults.vnc_base`, default `5900`, so `link: 10` →
  `5910`); the socket binds to `defaults.vnc_bind` (default `0.0.0.0` —
  reachable from any host that can route to the bhyve host). `vmctl status`
  prints the VNC endpoint (e.g. `vnc 0.0.0.0:5910`) for graphics-enabled VMs.
  **Security caveat:** bhyve's VNC console is unauthenticated — anyone who can
  reach the port gets the console with no password. To restrict access, set
  `defaults.vnc_bind: 127.0.0.1` and reach it over an SSH tunnel instead:
  `ssh -L 5910:localhost:5910 <host>`, then point a VNC client at
  `localhost:5910`.
- **Persistent UEFI vars** (`bootvars`) — generated when `efi_vars: true` is
  set on a VM: a writable UEFI variables store, copied from the host's
  pristine template (`defaults.uefi_vars_template`, default
  `/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd`) into
  `<vm_root>/<name>/<name>-uefi-vars.fd` on first start. Boot order and other
  UEFI settings then persist across restarts. Default is `false`. Reset to
  factory with `vmctl set <name> --reset-efi-vars` (removes the file; it's
  recreated pristine on the next start); disable with `set --no-efi-vars`.
- **RTC time base** (`rtc.use_localtime`) — `rtc_localtime` sets whether a VM's
  real-time clock uses localtime (bhyve default) or UTC. Per-VM, with a
  `defaults.rtc_localtime` fallback (default `true` = localtime). For a UTC
  homelab set `defaults.rtc_localtime: false` once; Linux/BSD guests generally
  want UTC.
- **Wired memory** (`memory.wired`) — `memory_wired: true` pins the VM's guest
  memory so the host won't swap it out (latency/perf-sensitive VMs). Per-VM
  opt-in; default off.
- **SMBIOS identity** (`bios.*`/`system.*`/`board.*`/`chassis.*`) —
  `defaults.smbios` is a flat map of bhyve SMBIOS keys applied to every VM
  (consistent homelab hardware identity: manufacturer, product name, etc.). A
  per-VM `smbios:` map overrides or adds keys for a single VM (e.g. a unique
  `system.serial_number` / `chassis.asset_tag`). Keys must be in the
  `bios.`/`system.`/`board.`/`chassis.` namespaces. Layering:
  `defaults.smbios` < per-VM `smbios` < per-VM `options:`. Edited in the
  inventory YAML (no CLI).

Templates must NOT declare `cpus`, `memory.size`, `pci.0.3.*`, `pci.0.4.*`,
`pci.0.5.*`, `pci.0.6.*`, or (when `graphics: true`) `pci.0.7.*`/`pci.0.8.*` —
vmctl injects them all at start. At `start`, vmctl first verifies the
`bootrom` firmware file exists, failing fast with an install hint (install
the `uefi-edk2-bhyve` package) if it does not, then
renders the fully-resolved config to `<run_dir>/<name>.conf` (ephemeral,
regenerated every start — do not hand-edit) and launches
`bhyve -k <run_dir>/<name>.conf <name>`. Per-VM `options:` in the inventory
merge over the template; generated keys (including `cpus`/`memory.size`)
always win.

`import <name> --network NET` adopts a VM whose dataset already exists (e.g.
arrived via `zfs recv`): it allocates a fresh `link`, scans `<vm_root>/<name>/`
for `*.raw`, and registers the VM without provisioning.

To adopt a VM that's **already on this host** (started by hand or an old
script), pin its current link so its console (`/dev/nmdm<link>`) and netgraph
hook don't move:

    vmctl import pod34 --network labs_vlan50 --link 8

`--link` accepts any unused link (including the 0-9 band reserved from
auto-allocation). Omit it to auto-allocate the lowest free link. After importing,
stop the VM the old way once, then `vmctl start pod34` so vmctl's supervisor
takes over.

### Cloning

`clone <source> <newname>` provisions a new VM as a full independent copy of an
existing one — the homelab "golden template" workflow, though any VM can be a
source:

    vmctl clone pod34 web1                       # inherit pod34's bridge
    vmctl clone pod34 web1 --network other_vlan  # place on a different bridge
    vmctl clone pod34 web1 --cpus 2 --memory 4G --start

The clone's disks are copied via `zfs snapshot` + `zfs send | zfs recv`, so the
clone and source share no ZFS dependency — either can be `destroy`ed later
independently. The source must be stopped (pass `--force` to clone a running VM
with a crash-consistent snapshot).

Inherited from the source: template (`config`), `cpus`, `memory`, `graphics`,
`efi_vars`, `rtc_localtime`, `memory_wired`, `smbios`, `cloud_init`, and any
additional `networks:`. Reset fresh: `name`, `link`, and MAC (the primary MAC
is regenerated unless the source used bhyve auto-MAC, in which case the clone
stays auto; `--mac` overrides). `autostart` defaults off. An installer `iso:` is
not carried over, and UEFI vars are regenerated pristine on the clone's first
start.

`destroy <name>` removes a VM from the inventory (refusing if it is running);
`--purge` also `zfs destroy`s the dataset. All three honor `-n/--dry-run`.

## Networking

Network interfaces are generated by vmctl from the inventory and attached at
`pci.0.4.N`. The primary NIC comes from `network`/`link`/`mac` (+ optional
`mtu`, default 9000); a `networks:` list adds more (each `{ bridge:, mtu:,
mac: }`). `network: none` gives a console-only VM with no NICs. Templates must
NOT declare `pci.0.4.*`. Per-VM MTU defaults to 9000; `mac: generate` produces
a deterministic per-interface address. Manage NICs with `vmctl add-nic` /
`remove-nic`, and the primary with `vmctl set --network|--mac|--mtu`.

## Cloud-init / upgrade notes

- **Template resolution** — `cloud_init.user_data` names a template in `config_dir`
  (e.g. `web-base.yml`) or an absolute path. It is a shared source rendered at
  every start, not a per-VM copy. Pass `--cloud-init web-base.yml` (no directory
  prefix); vmctl joins it to `config_dir` automatically.
- **Variable substitution** — `%(name)`, `%(network)`, `%(link)`, `%(mac)`, and
  any keys added with `--var KEY=VAL` are substituted in the user-data template.
  An unknown `%(word)` token passes through unchanged, so `%(...)` syntax is
  effectively reserved for vmctl variables.
- **Migrating older VMs** — if a VM's `config:` pointed at the removed
  `pod-installer.conf` or `pod-cloudinit.conf` flavors, switch it to `pod.conf`.
  CD-ROM device lines are now generated automatically from the inventory; they
  must not appear in the template.

## Tests

```sh
ruby -Ilib -Itest test/run_all.rb
```

## Scope

vmctl manages VM **lifecycle**, **inventory**, and **provisioning**. It validates
(never creates) netgraph bridges — those are host infrastructure owned by your
`netgraph_setup` rc script.
