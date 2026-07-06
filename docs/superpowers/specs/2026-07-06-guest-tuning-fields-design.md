# vmctl guest-tuning fields (rtc + memory.wired) — Design

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Builds on:** `main` (through the fbuf `rfb` fix, PR #14).

## Summary

Add two guest-tuning inventory fields, both generated into the bhyve config like
every other managed key:

- **`rtc_localtime`** — controls `rtc.use_localtime`. bhyve defaults to localtime;
  Linux/BSD guests want UTC. Modeled like `cpus`/`memory` (a `defaults` knob + a
  per-VM override), **always emitted**. vmctl's default matches bhyve
  (`true` = localtime), so existing VMs are unchanged; a homelab sets
  `defaults.rtc_localtime: false` once for network-wide UTC.
- **`memory_wired`** — controls `memory.wired` (pin guest RAM, no host swapping).
  Per-VM opt-in boolean, **emitted only when true** (no global knob).

Both are produced by a single new `tuning_keys` generator appended last to the
`ConfigRenderer` generator list.

## Schema (`lib/vmctl/config.rb`)

- `VMEntry` gains `:rtc_localtime` (boolean; `nil` when unset) and `:memory_wired`
  (boolean; `false` when absent), both appended at the END of the struct member
  list.
- `Defaults` / `Config::DEFAULTS` gain `rtc_localtime` (default **`true`**,
  matching bhyve). No `memory_wired` default (per-VM opt-in only).
- `parse_defaults`: `rtc_localtime: merged['rtc_localtime']` (YAML boolean;
  no strict validation, mirroring `autostart`). `DEFAULTS['rtc_localtime'] = true`.
- `parse_vm`:
  - `rtc_localtime: body.key?('rtc_localtime') ? body['rtc_localtime'] : nil`
    (absent → `nil` so the default applies at render; an explicit `false` is
    preserved as `false`, NOT collapsed to nil).
  - `memory_wired: body.fetch('memory_wired', false)` (mirrors `graphics`).
- `vm_to_h`:
  - `h['rtc_localtime'] = vm.rtc_localtime unless vm.rtc_localtime.nil?`
    (emits `true` or `false` when set; omitted when unset — byte-stable).
  - `h['memory_wired'] = true if vm.memory_wired` (omitted when false).

## Generation (`lib/vmctl/config_renderer.rb`)

New `tuning_keys(vm)` generator, appended to the generator list (after
`firmware_keys`):

```ruby
def tuning_keys(vm)
  e = vm.entry
  keys = {}
  lt = e.rtc_localtime.nil? ? @defaults.rtc_localtime : e.rtc_localtime
  keys['rtc.use_localtime'] = lt.to_s
  keys['memory.wired'] = 'true' if e.memory_wired
  keys
end
```

- **`rtc.use_localtime` is always emitted.** Critical detail: the entry-vs-default
  resolution uses `.nil?`, **not** `||` — `e.rtc_localtime || @defaults.rtc_localtime`
  would treat an explicit `false` as unset and wrongly fall back to the default.
- **`memory.wired` is emitted only when `e.memory_wired` is truthy** (unset/false
  → key absent → bhyve's default of false).
- Generated keys run last, so both win over the flavor file and the `options:`
  map, like every other generator.

## Rendered-output ripple

Because `rtc.use_localtime` is now always emitted, **every** rendered config gains
a `rtc.use_localtime=true` line (for the default case) — semantically identical to
bhyve's implicit default, but a new line in the sorted output. Exact-output
renderer tests must be updated to include it. Known affected test:
`test_output_is_sorted` in `test/test_config_renderer.rb` (asserts the exact
sorted line array). Any other test asserting a full rendered body (vs
`assert_match` on individual keys) must add the `rtc.use_localtime=true` line in
sorted position (between `pci.*` and `zeta`, i.e. after `memory.size`/`memory.wired`
and before `zeta`). Tests using `assert_match`/`refute_match` on individual keys
need no change. `memory.wired` is opt-in, so it adds no ripple.

## CLI

- **`create`** (`lib/vmctl/commands/create.rb`): `--rtc-localtime` (→ true),
  `--no-rtc-localtime` (→ false), `--memory-wired` (→ true). Unset `rtc` → `nil`
  (inherit default); unset `memory-wired` → false. `build_entry` sets
  `rtc_localtime: opts[:rtc_localtime]` (nil when neither flag given) and
  `memory_wired: !!opts[:memory_wired]`.
- **`set`** (`lib/vmctl/commands/set.rb`): `--rtc-localtime` / `--no-rtc-localtime`
  (toggle to true/false), `--memory-wired` / `--no-memory-wired` (toggle). Apply
  clauses gated on `opts.key?(:rtc_localtime)` / `opts.key?(:memory_wired)` so an
  explicit `false` is applied, not skipped.
- Update the `set` usage line in `lib/vmctl/cli.rb`.

## Migration

None for inventories: `rtc_localtime` defaults to bhyve's localtime (existing VM
clocks unchanged), `memory_wired` defaults to false. Only the ephemeral rendered
config changes (gains the always-identical `rtc.use_localtime=true` line).
README documents both fields and the homelab tip
(`defaults.rtc_localtime: false` for network-wide UTC).

## Error handling

Both fields are plain booleans — no validation beyond truthiness. No new failure
modes.

## Testing

- **Config:** parse `rtc_localtime` true/false/absent (absent → nil; explicit
  `false` preserved as false, not nil); `defaults.rtc_localtime` default `true` +
  override `false`; `memory_wired` parse + round-trip only when true;
  `rtc_localtime` round-trip only when non-nil (both true and false emit).
- **Renderer (`tuning_keys`):** `rtc.use_localtime` always present;
  entry `true`/`false` override the default; entry nil → uses `@defaults`; **an
  explicit entry `false` renders `rtc.use_localtime=false`** (guards the `.nil?`
  vs `||` bug); `defaults.rtc_localtime=false` renders `false` when entry nil.
  `memory.wired=true` present only when `memory_wired`; absent otherwise.
  Update `test_output_is_sorted` (and any full-body assertions) for the new line.
- **Commands:** `create --rtc-localtime`/`--no-rtc-localtime`/`--memory-wired`
  record the fields; `set` toggles each (including `--no-rtc-localtime` → false
  round-trips, proving `opts.key?` gating).

## Out of scope (YAGNI)

- `acpi_tables_in_memory` — Windows/vTPM-only; deferred to that feature.
- `com2` — a second serial port needs nmdm allocation + attach plumbing; its own
  small feature if a use arises.
- `defaults.memory_wired` global knob — wiring every VM's RAM is not a homelab
  default anyone wants.
