# vmctl SMBIOS identity (global) — Design

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Builds on:** `main` (through guest-tuning fields, PR #15).

## Summary

Add a global `defaults.smbios` map — a flat set of literal bhyve_config SMBIOS
keys (`bios.*`/`system.*`/`board.*`/`chassis.*`) applied to **every** VM, so a
homelab can present a consistent hardware identity (manufacturer, product name,
etc.) across all guests — plus an optional per-VM `smbios:` map that overrides or
adds to the global identity for that VM (e.g. a unique `system.serial_number` or
`chassis.asset_tag`). SMBIOS is a new render **layer**, not a device generator.

## Layering

The global `defaults.smbios` and the per-VM `smbios` maps sit between the base
template and the per-VM `options:` map (broadest to narrowest):

```
template  <  defaults.smbios  <  vm.smbios  <  options:  <  generators (disks/nics/cpu/mem/…)
```

Consequences:
- A global SMBIOS value **overrides** a stray SMBIOS line in a base template.
- A per-VM `smbios` value **overrides** the global `defaults.smbios` value for
  that VM (per-VM identity beats the shared identity).
- A per-VM `options:` entry still **overrides** both (the `options:` escape hatch
  remains the ultimate per-VM override).
- The device generators are unaffected — SMBIOS keys never collide with the
  `pci.*`/`cpus`/`memory.*`/`rtc.*` keys generators own.

## Schema (`lib/vmctl/config.rb`)

- `Defaults` gains `:smbios` (Hash; default `{}`), appended at the END of the
  struct member list.
- `VMEntry` gains `:smbios` (Hash; default `{}`), appended at the END of the
  struct member list.
- `Config::DEFAULTS` gains `'smbios' => {}`.
- `parse_defaults`: `smbios: parse_smbios(merged['smbios'])`.
- `parse_vm`: `smbios: parse_smbios(body['smbios'])` — **reuses the same helper**,
  so per-VM SMBIOS gets identical namespace validation and stringification.
- New `parse_smbios(v)` helper (shared by both levels):
  - `nil` → `{}` (absent).
  - Must be a `Hash` → else `ConfigError, "'smbios' must be a mapping"`.
  - **Every key must start with one of `bios.`, `system.`, `board.`, `chassis.`**
    → else `ConfigError, "invalid smbios key '<k>' (must be bios./system./board./chassis.*)"`.
    This namespace guard keeps `smbios:` scoped to SMBIOS and prevents smuggling
    arbitrary bhyve keys (e.g. `pci.0.3.0.path`) in globally.
  - Returns a new Hash with String keys and String values (values coerced via
    `to_s`, so YAML numerics like `bios.version: 14.0` become `"14.0"`).
- `to_h` (defaults): no special handling needed. The existing `to_h` filters
  defaults equal to `DEFAULTS` (`select { |k,v| DEFAULTS[k.to_s] != v }`), so an
  empty `smbios` (`{}` == `DEFAULTS['smbios']`) is omitted (byte-stable) and a
  non-empty one is emitted.
- `vm_to_h`: emit the per-VM map only when non-empty —
  `h['smbios'] = vm.smbios unless vm.smbios.nil? || vm.smbios.empty?` (existing
  inventories stay byte-stable).

## Generation (`lib/vmctl/config_renderer.rb`)

`ConfigRenderer#resolve` gains one inserted line, after the template parse and
**before** the `options:` merge:

```ruby
def resolve(vm)
  text = File.binread(vm.template_path)
  map = parse_pairs(substitute(text, vm.entry))
  stringify(@defaults.smbios).each { |k, v| map[k] = v }   # NEW: global SMBIOS
  stringify(vm.entry.smbios).each  { |k, v| map[k] = v }   # NEW: per-VM SMBIOS (beats global)
  stringify(vm.entry.options).each { |k, v| map[k] = v }
  generators.each { |gen| gen.call(vm).each { |k, v| map[k] = v } }
  map
end
```

`stringify` (existing private helper) coerces keys/values to strings and tolerates
a nil/empty hash. No generator is added; SMBIOS is a static layer (global then
per-VM), not a per-VM-*derived* key set.

## CLI

None. SMBIOS is edited directly in the inventory YAML (`defaults.smbios` and a
per-VM `smbios:` block) — consistent with the per-VM `options:` map, which also
has no CLI editor. A map of ~20 possible keys is not ergonomic on the command
line.

## Migration

None. Both `smbios` maps default to `{}`, so nothing is emitted for existing
inventories and no existing test or rendered config changes. Only inventories
that add a `defaults.smbios` or per-VM `smbios:` block get the keys.

## Error handling

- `smbios` (defaults OR per-VM) not a mapping → `ConfigError` at load.
- A key outside the four SMBIOS namespaces (either level) → `ConfigError` at load.
- No value validation beyond `to_s` coercion (bhyve accepts arbitrary strings).

## Testing

- **Config parse (both levels):** a valid `defaults.smbios` and a valid per-VM
  `smbios` map load; keys/values are strings (numeric YAML value coerced, e.g.
  `bios.version: 14.0` → `"14.0"`); a non-mapping `smbios` raises `ConfigError`;
  a key with a disallowed prefix (e.g. `pci.0.3.0.path`, `foo.bar`) raises
  `ConfigError` at each level; absent `smbios` → `{}`.
- **Round-trip:** a non-empty `defaults.smbios` is present under `defaults`; a
  non-empty per-VM `smbios` is present under the VM; absent/empty ones are
  omitted (both levels).
- **Renderer layering:** with `defaults.smbios` set, the keys appear in the
  rendered config; a **per-VM `smbios`** entry for the same key overrides the
  global value (per-VM beats global); a per-VM `options:` entry overrides a
  per-VM `smbios` value (options beats smbios); a base template line for a smbios
  key is overridden by `defaults.smbios` (global beats template); a VM with no
  SMBIOS at either level renders no SMBIOS keys.

## Out of scope (YAGNI)

- The top-level `uuid` SMBIOS key — bhyve's deterministic default (hashed from
  host hostname + VM name) is fine; a dedicated field can be added later if
  control is ever needed.
- CLI flags for editing SMBIOS values.
- Value-level validation (lengths, formats) — bhyve accepts arbitrary strings.
