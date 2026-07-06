# vmctl CPU/memory as inventory fields — Design

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Builds on:** `main` (through stale-vmm detection, PR #10).

## Summary

Move the last hardware settings out of templates and into the inventory: per-VM
`cpus:` and `memory:`, generated into the bhyve config like disks/NICs/CDs. A VM's
`cpus`/`memory` come from its inventory entry, falling back to new
`defaults.cpus` / `defaults.memory` (**1** / **1G**). Templates keep only OS-core
keys (bootrom, hostbridge, rng, lpc/console, acpi flags). `create`/`set` gain
`--cpus` / `--memory`.

## Schema

- `VMEntry` gains `:cpus` (Integer, nil when unset) and `:memory` (size String,
  nil when unset).
- `Defaults` gains `:cpus` and `:memory`; `Config::DEFAULTS` adds `'cpus' => 1`
  and `'memory' => '1G'`.
- **`memory` uses vmctl's size format** (`Sizes.parse`: 1024-based, single-letter
  suffix `K`/`M`/`G`/`T`, e.g. `1G`, `512M`, `2048M`). `1GB` is **not** a valid
  token. Renders to the bhyve key `memory.size=<value>`.

### `Config` changes (`lib/vmctl/config.rb`)

- `parse_defaults`: read `cpus`/`memory` from the merged defaults; `cpus` via
  `Integer(...)` (positive), `memory` validated by `Sizes.parse` — else
  `ConfigError`.
- `parse_vm`: `cpus: parse_cpus(body['cpus'])`, `memory: parse_memory(body['memory'])`
  — each returns nil when absent, else validates (positive integer / valid size)
  and raises `ConfigError` on bad input.
- `vm_to_h`: emit `'cpus'`/`'memory'` only when non-nil (existing inventories stay
  byte-stable).

## Generation

A new `hardware_keys(vm)` generator, appended to `ConfigRenderer`'s generator
list, **always** emits both keys (entry value or default):

```ruby
def hardware_keys(vm)
  {
    'cpus'        => (vm.entry.cpus   || @defaults.cpus).to_s,
    'memory.size' => (vm.entry.memory || @defaults.memory).to_s
  }
end
```

This is the first real use of `ConfigRenderer`'s `@defaults` ivar (previously
flagged as dead). Generators run last, so generated `cpus`/`memory.size`
**override** the flavor file and the `options:` map — CPU/memory are now truly
inventory-controlled.

## Precedence / `options:` interaction

Because generated keys win, a VM that set `cpus` or `memory.size` via the generic
`options:` escape hatch will now have those overridden by the first-class field
(or the default). This is the same "generated keys win" rule as disks/NICs/CDs;
operators should use `cpus:` / `memory:` (or `--cpus` / `--memory`). Documented in
the migration note.

## CLI

- **`create --cpus N --memory SIZE`** — sets `entry.cpus` / `entry.memory`
  (omitted → nil → defaults apply at render). Validates `N` (positive integer) and
  `SIZE` (`Sizes.parse`) → `CommandError` on bad input.
- **`set --cpus N --memory SIZE`** — edits the fields (only provided flags change),
  same validation. Takes effect on next start (like other `set` edits).

## Migration

- Remove `cpus=2` / `memory.size=4G` from `examples/pod.conf`; tighten its header
  (templates declare OS-core only — no cpus/memory/disks/NICs/CDs).
- Add `cpus: 1` / `memory: 1G` under `defaults:` in `examples/inventory.yml`, and a
  README note that CPU/memory are inventory fields (per-VM `cpus:`/`memory:` with a
  `defaults` fallback) and no longer belong in templates.
- Existing inventories need no change — the fields default to 1 / 1G. A deployed
  template that still declares `cpus`/`memory.size` is harmless (generated keys
  win) but now redundant.

## Error handling

- Bad per-VM or default `cpus` (non-integer / ≤ 0) or `memory` (unparseable) →
  `ConfigError` at load.
- Bad `--cpus` / `--memory` on `create`/`set` → `CommandError`.

## Testing

- **`Config`**: `cpus`/`memory` parse + round-trip; absent → nil (not emitted);
  bad cpus (`0`, `"x"`) and bad memory (`"1GB"`, `"huge"`) raise `ConfigError`;
  `defaults.cpus`/`defaults.memory` parse (custom + fallback to 1 / 1G).
- **`ConfigRenderer`**: `hardware_keys` emits `cpus`/`memory.size` from the entry;
  falls back to `defaults` when the entry is nil; **overrides** a flavor
  `cpus=`/`memory.size=` line and an `options:` `cpus`.
- **Commands**: `create --cpus/--memory` records the fields + bad-value errors;
  `set --cpus/--memory` edits + round-trips; unset create → renders defaults.
- **Migration**: rendering a VM on the trimmed `pod.conf` still yields
  `cpus`/`memory.size`.

## Out of scope (YAGNI)

- Other bhyve memory keys (`memory.guest_in_core`, `memory.wired`) — only
  `memory.size`.
- CPU topology (`sockets`/`cores`/`threads`) — just `cpus` (vCPU count).
- Removing the `options:` escape hatch — it stays for arbitrary keys; cpus/memory
  simply become first-class and win over it.
