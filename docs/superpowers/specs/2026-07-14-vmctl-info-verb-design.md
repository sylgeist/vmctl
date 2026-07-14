# vmctl `info` verb — design

**Date:** 2026-07-14
**Status:** Approved for planning

## Problem

There's no clean way to see a VM's allocated resources. `vmctl status` shows
only liveness (running/stopped/stale, pid, network link, VNC). `vmctl dump`
shows the fully-rendered bhyve config but is too noisy for a quick "what is this
VM sized at?" glance. Users want a focused per-VM resource summary.

Note: bhyve allocations are static for a VM's lifetime (no CPU/memory hotplug),
so the resolved configured allocation equals the actual allocation for a running
VM as long as the inventory wasn't edited after boot. This feature reports
**configured allocation only** — no live utilization (RSS, CPU%, on-disk image
size). That was explicitly scoped out.

## Solution

A new read-only verb: `vmctl info [<name>...] [--all]`.

- Target resolution mirrors `status` via `Commands::Base#targets` — no-arg uses
  the existing default target behavior, `--all` selects all VMs.
- Prints one block per VM, blank-line separated for multi-target output.
- Purely read-only: reuses the same liveness checks `status` already performs
  (`test -e /dev/vmm/<name>`, pidfile + `kill -0`). No new introspection, no
  shelling out to bhyve/ps.

### Output format (aligned)

```
web01: running (pid 4821)
  cpus     2
  memory   4G  (wired)
  disks    root  20G  /vm/web01/root.img
           data  100G /vm/web01/data.img
  network  bridge0  link tap3
```

- **Header** — reuses status's state logic: `running (pid N)` / `stopped` /
  `stale`.
- **cpus / memory** — read from `vm.resolved_config` (bhyve keys `cpus` and
  `memory.size`). This is the single source of truth: the same resolved values
  the VM boots with, so `info` can never drift from `dump`/actual boot config.
- **wired** — `(wired)` suffix on the memory line, shown only when
  `memory.wired` is present/true in the resolved config.
- **disks** — one row per disk: `<suffix>  <size>  <path>`. Size comes from
  `entry.disks` (disk size is not a bhyve boot key, so it's not in
  `resolved_config`); path comes from the resolved disk keys
  (`pci.0.3.N.path`). Suffix is the disk's logical name/suffix.
- **network** — one row per NIC: `<bridge>  link <tap>`.

## Components

**New:** `lib/vmctl/commands/info.rb` — `Commands::Info < Commands::Base`,
shaped like `commands/status.rb`. Responsibilities:
1. Resolve targets.
2. For each VM: derive header state (reuse the running/stopped/stale logic that
   status uses), pull cpus/memory/wired from `vm.resolved_config`, disks from
   `entry.disks` + resolved disk paths, networks from the NIC entries.
3. Format aligned output; print block(s).

**Edits:** `lib/vmctl/cli.rb` — three registration points:
1. `require_relative 'commands/info'` in the require block.
2. `'info' => Commands::Info` in the `COMMANDS` hash.
3. An `info` line in the `USAGE` heredoc.

No changes to `config.rb`, `config_renderer.rb`, or `vm.rb` — `info` only reads
existing accessors (`vm.resolved_config`, `vm.entry`, liveness helpers).

## Data flow

```
targets(names, all:) ─▶ [VM, ...]
   for each VM:
     state   ◀─ vm.running?/supervisor_alive?/stale?  (same as status)
     cpus    ◀─ vm.resolved_config['cpus']
     memory  ◀─ vm.resolved_config['memory.size'] (+ 'memory.wired')
     disks   ◀─ entry.disks (size) + resolved pci.0.3.N.path (path)
     network ◀─ entry NIC list (bridge, link/tap)
   └▶ formatted block
```

## Error handling

- Unknown VM name: same behavior as other commands via `vm_for`/`targets`
  (surfaces the existing not-found error).
- A stopped VM still shows full allocation (config is available regardless of
  run state); only the header state differs.

## Testing

Unit tests in the command's spec, following the existing command test pattern
(injected executor for liveness stubbing):

1. Stopped VM — header `stopped`, full allocation shown.
2. Running VM — liveness/pid stubbed via executor, header `running (pid N)`.
3. Wired memory — `(wired)` suffix present; absent when not wired.
4. Multi-disk / multi-NIC VM — locks aligned formatting for repeated rows.
5. `--all` / multiple names — one block per VM, correct separation.

## Out of scope (YAGNI)

- Live utilization (process RSS, CPU%, actual on-disk image size).
- Any bhyve/ps runtime introspection.
- Extending `status` or adding a `--resources` flag (chose a dedicated verb).
- Machine-readable output (JSON/YAML) — can follow later if needed.
