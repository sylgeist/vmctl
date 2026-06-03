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

- Ruby >= 3.0
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

At `start`, vmctl reconstructs the same invocation you would run by hand:

```sh
bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 pod34
```

and supervises it: when the guest reboots, bhyve exits and vmctl relaunches it;
when it powers off, vmctl runs `bhyvectl --destroy` and stops.

## Usage

```
vmctl [options] <command> [args]

  start [name|--all]   Start VM(s) under a supervisor.
  stop  [name|--all]   Graceful poweroff (TERM); --force destroys immediately.
  restart <name>       Graceful stop then start.
  status [name]        Running/stopped, pid, network, link.
  console <name>       Attach to the VM's nmdm console (cu); ~. to detach.
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

## Tests

```sh
ruby -Ilib -Itest test/run_all.rb
```

## Scope

vmctl manages VM **lifecycle** and **inventory**. It validates (never creates)
netgraph bridges — those are host infrastructure owned by your `netgraph_setup`
rc script. Provisioning (`create`, `import`, `destroy`, cloud-init) is a planned
Phase 2.
