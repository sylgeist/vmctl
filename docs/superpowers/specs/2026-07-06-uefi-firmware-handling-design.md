# vmctl UEFI firmware handling — Design

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Builds on:** `main` (through graphics/VNC console, PR #12).

## Summary

Two related start-time firmware concerns, delivered as one feature:

- **Part A — bootrom presence check.** At `start`, verify the resolved `bootrom`
  firmware file exists; fail fast with a clear message instead of letting bhyve
  die cryptically.
- **Part B — opt-in persistent EFI vars.** A per-VM `efi_vars: true` inventory
  field gives the VM a writable UEFI variables store (`bootvars=`), copied from a
  pristine template. Boot-order and other UEFI settings then persist across
  restarts. Reset-to-factory is "remove the file" (recreated pristine at next
  start).

## Part A — bootrom presence check at start

### Renderer refactor (enables the check without double-rendering)

`bootrom=` lives in the base template, so it is only known after rendering. Split
`ConfigRenderer#render` so the resolved key map is reusable:

- `ConfigRenderer#resolve(vm) → Hash` — the fully merged/generated key map
  (flavor `%()`-substituted → `options:` → generators). This is the current body
  of `render` up to the final `sort/join`.
- `ConfigRenderer#render(vm) → String` — calls `resolve`, then
  `map.sort.map { "#{k}=#{v}" }.join("\n") + "\n"` (unchanged output).
- `VM#resolved_config → Hash` — memoized `ConfigRenderer.new(@defaults).resolve(self)`.
- `VM#render_config` / `write_config` stay behavior-identical (serialize the same
  map). Rendered-file bytes are unchanged.

### The check

In `Start#start_one`, during preflight (alongside the NIC-bridge checks, before
launching):

- `rom = vm.resolved_config['bootrom']`
- If `rom` is set and `executor.success?('test', '-e', rom)` is false →
  `raise CommandError, "bootrom not found: #{rom} (install the uefi-edk2-bhyve package?)"`.
- If `bootrom` is absent from the config, skip the check (no assumption that
  every template uses UEFI).

Hard error (refuse to start), mirroring the missing-bridge behavior. Uses the
executor `test -e` probe — the established pattern (`VM#running?`) — so it is
driven by `FakeExecutor` probes in tests.

## Part B — opt-in persistent EFI vars

### Schema (`lib/vmctl/config.rb`)

- `VMEntry` gains `:efi_vars` (boolean; `false` when absent, via
  `body.fetch('efi_vars', false)` — mirrors `graphics`/`autostart`).
- `Defaults` / `Config::DEFAULTS` gain `uefi_vars_template`, default
  `/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd` (the pristine vars store
  shipped by `uefi-edk2-bhyve`).
- `vm_to_h` emits `'efi_vars' => true` only when truthy (existing inventories
  stay byte-stable).

### Vars file location (`lib/vmctl/vm.rb`)

- `VM#uefi_vars_path` → `File.join(dir, "#{name}-uefi-vars.fd")` — i.e.
  `<vm_root>/<name>/<name>-uefi-vars.fd`. It lives in the per-VM ZFS dataset dir
  alongside disks, so `destroy --purge` (`zfs destroy <zpool>/<name>`) removes it
  automatically. No change to `destroy` is needed.

### Generation (`lib/vmctl/config_renderer.rb`)

A generator emitting the vars key, appended last to the generator list (same
"generated keys win" seam as disks/NICs/CDs/hardware/graphics):

```ruby
def firmware_keys(vm)
  return {} unless vm.entry.efi_vars
  { 'bootvars' => vm.uefi_vars_path }
end
```

**⚠️ Implementation-time verification:** confirm the exact bhyve_config key name
for the UEFI variables file against `man bhyve_config` on the host before
committing (`bootvars` is the expected key; a wrong name fails silently — no
persistence, no error). If the man page names it differently, use that name and
update the tests accordingly.

### Provisioning (lazy, single path — in `Start`)

Start ensures the vars file exists for an `efi_vars` VM, as a preflight step
(before launch, after the bootrom check):

- If `vm.entry.efi_vars`:
  - template = `config.defaults.uefi_vars_template`
  - If `executor.success?('test', '-e', template)` is false →
    `raise CommandError, "UEFI vars template not found: #{template} (install the uefi-edk2-bhyve package?)"`.
  - If `executor.success?('test', '-e', vm.uefi_vars_path)` is false →
    `executor.run('cp', template, vm.uefi_vars_path)` (copy pristine).
  - If the per-VM file already exists, do nothing (persistence preserved).

This is the ONLY provisioning path. `create` stays disk-only. Enabling
`efi_vars` on an existing VM "just works" — the file is created on its next
start.

### Reset / clear

`set --reset-efi-vars` removes the per-VM vars file so the next start recreates
it pristine:

- If `vm.entry.efi_vars` is false → `raise CommandError, "#{name} does not have efi_vars enabled"`.
- Else `executor.run('rm', '-f', vm.uefi_vars_path)` and record the change.
- Print the usual "takes effect on next start" notice (`note_next_boot`).

### CLI

- **`create --efi-vars`** — sets `entry.efi_vars = true` (value-less boolean flag,
  like `--graphics`). Omitted → false.
- **`set --efi-vars` / `set --no-efi-vars`** — toggle the field (like
  `--graphics`/`--no-graphics`). `--no-efi-vars` unsets the field and leaves the
  file in place (harmless; reused if re-enabled; wiped on purge).
- **`set --reset-efi-vars`** — remove the vars file (see Reset above).
- Update the `set` usage line in `lib/vmctl/cli.rb` to list the new flags.

## Migration

None. `efi_vars` defaults to false; `bootvars` is emitted only when enabled. No
template changes. The bootrom check only fires when a template declares
`bootrom` (all real ones do) and is satisfied whenever the firmware package is
installed.

## Error handling

- Missing `bootrom` file at start → `CommandError` (Part A).
- `efi_vars` enabled but `uefi_vars_template` missing at start → `CommandError`.
- `set --reset-efi-vars` on a VM without `efi_vars` → `CommandError`.
- `efi_vars` is a plain boolean — no parse-time validation beyond truthiness.

## Testing

- **Renderer refactor:** `resolve` returns the expected map; `render` output is
  byte-identical to before (existing renderer tests must stay green).
- **Part A:** a rendered config carrying `bootrom=<path>` → `start` refuses when
  the probe `test -e <path>` is false (assert `CommandError` + message), starts
  when true; a config with no `bootrom` skips the check.
- **Part B schema:** `efi_vars` parse + round-trip; absent/false → omitted from
  `to_h`; `defaults.uefi_vars_template` default + override.
- **Part B generation:** `firmware_keys` emits `bootvars=<uefi_vars_path>` when
  `efi_vars`, nothing when not.
- **Part B path:** `VM#uefi_vars_path` = `<vm_root>/<name>/<name>-uefi-vars.fd`.
- **Part B provisioning:** `start` copies the pristine template when the file is
  missing (assert `['cp', template, path]` in `exec.runs`); does NOT copy when the
  file exists; refuses when the template is missing.
- **Part B reset:** `set --reset-efi-vars` runs `['rm', '-f', path]`; errors when
  `efi_vars` is disabled.
- **Part B CLI:** `create --efi-vars` and `set --efi-vars`/`--no-efi-vars` toggle
  the field and round-trip.

## Out of scope (YAGNI)

- Secure Boot / UEFI key enrollment.
- Editing or inspecting vars content from the host.
- Per-VM custom vars templates (one host-wide pristine template only).
- Eager vars-file provisioning at `create` (lazy-at-start is the single path).
- Removing the vars file on `--no-efi-vars` (left in place; wiped on purge).
