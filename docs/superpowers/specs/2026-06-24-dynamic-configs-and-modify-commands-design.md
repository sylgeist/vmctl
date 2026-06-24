# vmctl dynamic configs + VM modify commands — Design

**Date:** 2026-06-24
**Status:** Approved design, pre-implementation
**Builds on:** Phase 1 (lifecycle) + Phase 2 (provisioning) + `dump`/`import`/`create --iso`, all on `main`.

## Summary

Two related changes, built as one cohesive piece because the second is hollow
without the first:

1. **Dynamic config generation.** Stop relying on hand-maintained `pci.*` disk
   declarations in shared templates. Instead, vmctl renders a VM's
   **fully-resolved bhyve config** from a *base flavor file* + the VM's inventory
   entry, writes it to an **ephemeral, always-latest** `run_dir/<name>.conf`, and
   launches `bhyve -k run_dir/<name>.conf <name>`. The inventory `disks:` list
   becomes the single source of truth for disk topology — vmctl generates the
   `pci.*` lines from it.

2. **Four `modify` commands** — `add-disk`, `grow-disk`, `remove-disk`, `set` —
   thin handlers that edit the inventory (+ backing files) and persist via the
   existing `Config#save`. Because topology is now generated from the inventory,
   these commands genuinely change what the guest boots with on the next start.

## Motivation

Today the inventory `disks:` list is only a *provisioning manifest* (what files
`create`/`import`/`destroy` touch). What actually attaches to the guest is
hard-coded in the template's `pci.*.path` lines (`examples/pod.conf`), and the
template is shared across VMs via `%(name)` substitution. So an inventory-only
`add-disk` would create a `.raw` file that never attaches. Moving topology
generation into vmctl removes that manual-sync trap and makes per-VM disk
changes real.

## Part 1 — Dynamic config generation

### Layering / precedence

A VM's final config is a flat, dotted-key bhyve namespace assembled from three
layers (lowest → highest precedence):

1. **Base flavor file** — the shared OS-core: acpi flags, `bootrom`,
   `hostbridge`, `virtio-rnd`, `lpc`/console, the `virtio-net` wiring, and
   default `cpus`/`memory.size`. Selected per-VM by the existing inventory
   `config:` field (default `defaults.template`). Shipping more than one base
   (`base-linux.conf`, `base-freebsd.conf`, …) is how OS **flavors** are
   supported — no new concept, just the existing selector pointed at
   purpose-built bases. Base files **no longer declare disks.**
2. **Per-VM `options:`** — a new optional inventory map of raw bhyve keys merged
   on top of the base, for one-off tweaks (`cpus`, `memory.size`, an extra
   device) without forking a base file.
3. **vmctl-managed keys** — disks (generated from `disks:`) and the iso CD
   device (when `iso:` is set). Applied last, so they always win: an `options:`
   entry that collides with a managed `pci.*` disk key is overwritten (managed
   topology stays authoritative). Net/link/mac stay in the base via `%()`
   substitution (unchanged behavior, just resolved by vmctl).

Order within the rendered file does not matter to bhyve (it's a namespace); the
renderer emits keys **sorted** for deterministic output and testability. Comments
are dropped in the generated ephemeral file (base files keep their own comments).

### `ConfigRenderer` (new — `lib/vmctl/config_renderer.rb`)

Single purpose: pure text/data in → resolved config text out. No I/O of its own
(the caller decides whether to write a file or print to stdout), which keeps it
trivially unit-testable.

```ruby
class ConfigRenderer
  def initialize(defaults)
    @defaults = defaults
  end

  # vm: a VM. Returns the fully-resolved bhyve config as a String.
  def render(vm)
    base   = substitute(File.read(vm.template_path), vm)  # %() -> concrete
    pairs  = parse_pairs(base)                              # [[k,v],...]
    map    = pairs.to_h
    map.merge!(stringify(vm.entry.options || {}))           # layer 2
    map.merge!(disk_keys(vm))                               # layer 3 (disks)
    map.merge!(iso_keys(vm)) if vm.entry.iso                # layer 3 (iso)
    map.sort.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
  end
end
```

- `substitute` resolves `%(name) %(network) %(link) %(mac)` against the entry
  (same variables bhyve substitutes today; we resolve them so the ephemeral file
  is fully concrete).
- `parse_pairs` reads `key=value` lines, skipping blanks and `#` comments.
- `disk_keys` generates, for disk index *N* (0-based) over `vm.entry.disks`:
  `pci.0.3.N.device=nvme`, `pci.0.3.N.path=<vm.dir>/<disk.file>`. Disks occupy
  functions 0–7 of slot `pci.0.3` (**max 8 disks**; documented limit, spillover
  to another slot is a later concern). Root is index 0 by convention (it is the
  first disk in the entry).
- `iso_keys` injects an AHCI CD-ROM device for `vm.entry.iso`, mirroring the
  device keys used by the current installer template (see
  `2026-06-12-vmctl-create-iso-design.md`) at a reserved slot
  (⚙️ `pci.0.5`); exact keys finalized against that template during
  implementation.

### `VM` changes (`lib/vmctl/vm.rb`)

- **`config_path`** → `File.join(@defaults.run_dir, "#{name}.conf")` — the
  ephemeral generated config path.
- **`render_config`** → `ConfigRenderer.new(@defaults).render(self)` — the
  resolved text (used by `dump` and the supervisor).
- **`write_config`** → writes `render_config` to `config_path` (creating
  `run_dir`); returns the path. Called on the launch path.
- **`bhyve_argv`** collapses to `['bhyve', '-k', config_path, name]`. The
  network/link/mac/iso `-o` overrides are gone — they're baked into the rendered
  file.
- **Removed:** `template_wants_iso?` and `dump_command` (see below);
  `bhyve_command` stays (joins `bhyve_argv` for logging/dry-run display).
- `template_path` is retained but now points at the **base flavor** file.

### Launch path

- **`Supervisor#start`** writes the config before forking: in `ensure_dirs`
  (already makes `run_dir`/`log_dir`) add `@vm.write_config`. The reboot loop
  reuses the same file (inventory is fixed for a supervisor's lifetime;
  "always-latest" is achieved by re-rendering on each `vmctl start`).
- **`Commands::Start#start_one`** dry-run branch prints `vm.render_config`
  (what *would* launch) instead of only the command string.
- **`validate_iso_pairing!`** (in `Commands::Base`) is **removed**, along with
  its calls in `start`/`create`. Iso pairing is no longer a template concern —
  the renderer injects the CD device iff `iso:` is set.

### `dump` becomes a renderer

`Commands::Dump` prints `vm.render_config` directly (no bhyve subprocess needed
for the common case). ⚙️ Optionally it may still pipe the rendered file through
`bhyve -k <file> -o config.dump=1` to show bhyve's own parse; default to printing
the rendered text (simpler, no bhyve dependency, works with no disks present).
`VM#dump_command` is removed.

### Migration

- Ship `examples/base.conf` (renamed/trimmed from `pod.conf`) **without** the
  `pci.0.3.*` disk lines. Optionally ship a second flavor to demonstrate the
  pattern.
- Document in the README that base/template files must no longer declare disks
  (vmctl injects them) and that `run_dir/<name>.conf` is ephemeral, regenerated
  each start, and must not be hand-edited.
- Pre-1.0, single-operator deployment: a clean break is acceptable; no automatic
  template rewriting.

### `Config` changes

- Add `options` to `VMEntry` (`Struct` keyword member), parsed from
  `body['options']` (a Hash, default `{}`), validated as a mapping. `vm_to_h`
  emits `'options'` only when non-empty (keeps existing inventories byte-stable).

## Part 2 — modify commands

All four extend `Commands::Base`, resolve the target with `vm_for(name)`, mutate
the `VMEntry`/disks, and persist with `config.save(config.path)` (atomic
temp-rename; skipped under `--dry-run`). Disks are addressed by **suffix**
derived from `<name>-<suffix>.raw`.

### Running-VM policy

Per design decision: changes **warn and take effect on next boot** (natural —
the config regenerates on the next `start`). The one hard guard:
`remove-disk --purge` is **refused while the VM is running** (deleting an in-use
backing file). `add-disk`/`grow-disk` while running are allowed with a next-boot
notice (the guest does not see the new/grown file until reboot).

### `add-disk <vm> <suffix>:<size>[:from <img>]`

- Reuses `Create#parse_disk` grammar (extract it to a shared helper or
  `Disk.parse(name, spec)`).
- Validates: VM exists; suffix not already present; size parses (`Sizes.parse`);
  if `from`, image exists and size ≥ image size (same checks as `create`).
- `Provisioner#create_disk(File.join(vm.dir, file), size, from:)` lays down the
  `.raw`; append `Disk` to `entry.disks`; save.
- Prints `added disk <file> (<size>) to <vm>` + next-boot notice if running.

### `grow-disk <vm> <suffix> <new-size>`

- Grow-only: validates the matched disk exists and `Sizes.parse(new) >
  Sizes.parse(current)` (else `CommandError`).
- `truncate -s <new-size> <path>` (via executor; reuse provisioner — add
  `Provisioner#grow_disk(path, size)` wrapping the `truncate`), update the
  `Disk.size` in the entry, save.
- Note: growing the host file does not grow the guest filesystem — that's the
  guest's job after reboot. Documented in help/output.

### `remove-disk <vm> <suffix> [--purge]`

- Validates the disk exists. **Refuses to remove the `root` disk** (suffix
  `root`) — guard against orphaning the boot device.
- Removes the `Disk` from `entry.disks`; with `--purge`, deletes the backing file
  (refused if the VM is running). Save.
- Prints what was removed and whether the file was purged or left in place.

### `set <vm> [options]`

Edits scalar inventory fields, mirroring `create`'s options:
`--autostart/--no-autostart`, `--network NET` (re-validates the bridge via
`Netgraph#ensure_bridge!`), `--mac MAC|generate`, `--config TMPL` (base flavor),
`--iso FILE|--no-iso`, `--cloud-init FILE`. Only provided flags change; others
are untouched. Save. Prints a summary of changed fields + next-boot notice if
running.

### CLI wiring (`lib/vmctl/cli.rb`)

`require_relative` the four new command files; register
`'add-disk' / 'grow-disk' / 'remove-disk' / 'set'` in `COMMANDS`; add usage lines.

## Error handling

- Unknown VM / missing name / missing args → `CommandError` → CLI exit 1.
- Duplicate suffix on `add-disk`, removing `root`, shrinking on `grow-disk`,
  `--purge` while running → `CommandError` → exit 1.
- Bad size, missing image, image-larger-than-size → `CommandError` (reusing the
  `create` validations) → exit 1.
- Malformed `options:` (non-mapping) → `ConfigError` at load → exit 1.

## Testing

- **`ConfigRenderer`** (unit, pure): `%()` substitution; N-disk slot generation
  (0, 1, 8 disks); `options:` override precedence; managed keys beat colliding
  `options:`; iso present/absent; deterministic sorted output.
- **`VM`**: `config_path`, `bhyve_argv` reduces to `bhyve -k <path> <name>`,
  `write_config` writes resolved text.
- **`Supervisor`**: `start` writes the config (assert file content) before
  spawning; existing reboot-loop tests unaffected (injected runner).
- **modify commands** (with `FakeExecutor`, temp inventory): add-disk creates the
  file + appends + saves; duplicate suffix raises; grow-disk grows + rejects
  shrink; remove-disk drops entry, `--purge` deletes / refuses when running,
  refuses `root`; set changes only provided fields, `--network` checks the
  bridge. Round-trip the inventory through `Config.load` to assert persistence.
- **`Config`**: `options:` parse/round-trip; absent `options` stays absent in
  output.

## Out of scope (YAGNI)

- `set --option key=value` editing of the `options:` map (obvious later add).
- More than 8 disks / multi-slot disk spillover.
- Automatic template migration / rewriting of existing templates.
- Live hot-plug (bhyve can't, in this setup) — all changes are next-boot.
- Shrinking disks.
