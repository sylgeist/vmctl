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
  OS-core settings (cpus, memory, bootrom, hostbridge, rng, lpc console)
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

vmctl generates all device attachments from the inventory — templates declare
OS-core settings only. There is no template/iso pairing requirement:

- **Disks** (`pci.0.3.N`, max 8) — generated from the VM's `disks:` list.
- **NICs** (`pci.0.4.N`) — generated from `network`/`link`/`mac` + `networks:`.
- **Installer ISO** (`pci.0.5.0`) — generated when `iso:` is present; the ISO is
  referenced in place (never copied) and stays attached until you remove `iso:`.
  With UEFI this is harmless once the installed disk boots first.
- **Cloud-init seed ISO** (`pci.0.6.0`) — generated when `cloud_init:` is present;
  vmctl builds a NoCloud ISO (label "cidata") from the `user_data:` template and
  optional `vars:`.

Templates must NOT declare `pci.0.3.*`, `pci.0.4.*`, `pci.0.5.*`, or `pci.0.6.*`
devices — vmctl injects them all at start. At `start`, vmctl renders the
fully-resolved config to `<run_dir>/<name>.conf` (ephemeral, regenerated every
start — do not hand-edit) and launches `bhyve -k <run_dir>/<name>.conf <name>`.
Per-VM `options:` in the inventory merge over the template; generated device keys
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

## Tests

```sh
ruby -Ilib -Itest test/run_all.rb
```

## Scope

vmctl manages VM **lifecycle**, **inventory**, and **provisioning**. It validates
(never creates) netgraph bridges — those are host infrastructure owned by your
`netgraph_setup` rc script.
