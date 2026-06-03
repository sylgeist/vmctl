# vmctl Phase 2 — Provisioning (create / import / destroy + cloud-init) — Design

**Date:** 2026-06-03
**Status:** Approved design, pre-implementation
**Builds on:** Phase 1 (lifecycle), merged to `main`. See
`2026-06-03-vmctl-design.md` for the overall design and
`2026-06-03-vmctl-phase1-lifecycle.md` for what already exists.

## Summary

Phase 2 adds VM **provisioning** to vmctl: `create` (allocate IDs + lay down a
per-VM ZFS dataset, raw image files, and an optional cloud-init seed ISO),
`import` (adopt a `zfs recv`'d VM's existing disks as a new local entry), and
`destroy` (remove a VM, optionally purging its dataset). It introduces a
`Provisioner` and a `CloudInit` module, and three thin command handlers, all
driving the existing Phase 1 inventory and `Executor`.

Nothing about the inventory format changes: `create`/`import` write valid
Phase-1 VM entries, and the existing `start`/`stop`/etc. run them unchanged.

## Design principles carried from Phase 1

- **Templates stay opaque.** vmctl never parses the `bhyve_config` `.conf`
  template. The inventory `disks:` list is the sole source of truth for which
  raw files `create` lays down. The operator is responsible for the template
  referencing those paths and (for cloud-init) declaring the AHCI-CD device that
  points at the seed ISO. A typo'd template path surfaces at `start` as a bhyve
  error, not at `create`.
- **`Executor` is the only thing that shells out** (`zfs`, `truncate`, `cp`,
  `makefs`), so `Provisioner`/`CloudInit` are tested by injecting a fake.
- **Dry-run (`-n`) is honored end-to-end** — every mutating command prints the
  actions and writes nothing (no dataset, no files, no inventory change).
- **Raw image files, not zvols** (measurably faster in testing). One ZFS
  dataset per VM holds the image file(s) + cloud-init content, so a VM can be
  `zfs send`/`recv`'d as a self-contained unit.

## Inventory & `defaults` additions

Phase 2 adds three `defaults:` keys; per-VM schema is unchanged from Phase 1.

```yaml
defaults:
  # ... existing Phase 1 keys:
  # config_dir, vm_root, zpool, template, link_base, run_dir, log_dir
  image_dir: /bhyve/images   # where golden base images (the `from:` sources) live
  root_size: 20G             # default size of the single root disk on create
  root_from: base-14.raw     # optional default golden image for root (null → blank)
```

Defaults for the new keys (when absent): `image_dir` = `/bhyve/images`,
`root_size` = `20G`, `root_from` = `null` (blank root).

Resolution rules:
- A `from:` value (default `root_from` or a `--disk … from X`) resolves against
  `image_dir`. An absolute path is taken as-is.
- Disk filenames follow the `%(name)-<suffix>.raw` convention, e.g. the default
  root disk of `pod35` is `pod35-root.raw`.

A bare `vmctl create pod35 --network labs_vlan50` produces exactly one disk
(`pod35-root.raw`, sized `root_size`, cloned from `image_dir/root_from` or blank)
and this stored entry:

```yaml
vms:
  pod35:
    config: pod.conf          # defaults.template unless --config given
    network: labs_vlan50
    link: 12                  # allocated (lowest free >= link_base)
    mac: null
    autostart: false          # true only if --autostart
    disks:
      - { file: pod35-root.raw, size: 20G, from: base-14.raw }
    # cloud_init present only if --cloud-init was used:
    # cloud_init: { user_data: pod35-user-data.yml }
```

## Commands

### `create <name> [options]`

1. **Allocate** — `Allocator#next_link` (lowest free ≥ `link_base`). Resolve:
   - `network` — `--network` (required; error if omitted).
   - `config` — `--config`, else `defaults.template`.
   - `mac` — `--mac ADDR` pins a literal address; `--mac generate` uses
     `Allocator#generate_mac(name)`; omitted → `null` (bhyve auto-MAC).
2. **Build disk list** — start with the root disk from `defaults`
   (`root_size`/`root_from`), overridable by `--root-size SIZE` and
   `--root-from IMAGE`. Append one disk per repeatable
   `--disk <suffix>:<size>[:from <image>]` (e.g. `--disk zfs:100G`). Each disk:
   `{ file: "<name>-<suffix>.raw", size:, from: }`.
3. **Validate** (all → clear errors, no partial work):
   - name not in inventory (`Allocator#name_taken?`); link free.
   - bridge exists (`Netgraph#ensure_bridge!`).
   - template file exists (`<config_dir>/<config>`).
   - each `from:` image file exists (resolved via `image_dir`).
   - dataset dir `<vm_root>/<name>` and target disk files do not already exist
     (refuse rather than clobber).
4. **Provision** (`Provisioner`):
   - `zfs create <zpool>/<name>`.
   - For each disk, in `<vm_root>/<name>/`:
     - blank → `truncate -s <size> <path>`.
     - golden → `cp <image> <path>`, then `truncate -s <size> <path>` only if
       `<size>` is larger than the source (grow; never shrink — error if the
       requested size is smaller than the golden image).
5. **Cloud-init** (`CloudInit`, only with `--cloud-init FILE`):
   - Build a seed dir containing generated `meta-data`
     (`instance-id: <name>`, `local-hostname: <name>`) and a verbatim copy of
     the operator's `user-data` (`FILE`).
   - `makefs -t cd9660 -o rockridge,label=cidata <vm_root>/<name>/<name>-seed.iso <seeddir>`.
   - Copy `FILE` into the dataset as `<name>-user-data.yml`; record
     `cloud_init: { user_data: <name>-user-data.yml }` on the entry.
6. **Register** — insert the entry and atomic `Config#save`. `--autostart` sets
   the `autostart` flag. `--start` then boots it via the Phase 1 `Start` command.
7. **Dry-run (`-n`)** — print every `zfs`/`truncate`/`cp`/`makefs` action and the
   resulting entry; create no dataset, files, or inventory change.

Most creates reduce to `vmctl create pod35 --network labs_vlan50`.

### `import <name> [options]`

For a VM whose dataset already exists (e.g. arrived via `zfs recv`). Does **not**
provision disks.

- Allocate a **fresh** `link` on this host; resolve `network` (`--network`,
  required) and `config` (`--config`, else `defaults.template`); `mac` is `null`
  unless `--mac ADDR`.
- Scan `<vm_root>/<name>/` for `*.raw`; build the `disks` list with each file's
  on-disk size (`from:` omitted — these are existing images, not clones).
- Refuse if the name or link is taken, or the dataset dir is missing.
- Register via atomic `Config#save`.
- Cloud-init seed is **not** re-derived (operator's concern); an existing
  `*-seed.iso` is left in place but not tracked in `cloud_init`.
- Dry-run prints the discovered disks and resulting entry; writes nothing.

### `destroy <name> [--purge] [--yes]`

- Refuse if the VM is running (`vm.running?(executor)`).
- Remove the entry from the inventory (atomic `Config#save`).
- `--purge` also `zfs destroy <zpool>/<name>` (taking the disks + seed ISO with
  it). Without `--purge`, the dataset is left on disk (de-registered only).
- Confirm interactively (prompt for `yes`) unless `--yes`.
- Dry-run prints the `zfs destroy` (if `--purge`) and the inventory change;
  performs neither.

## Module layout

New files (Phase 1 layout otherwise unchanged):

```
lib/vmctl/
  provisioner.rb            # zfs create; raw image create (truncate) / clone (cp) / grow
  cloudinit.rb              # seed-dir assembly + makefs cidata ISO; meta-data generation
  commands/
    create.rb               # orchestrates allocator + provisioner + cloudinit + config save
    import.rb               # scan existing disks, allocate, register
    destroy.rb              # running-check, optional zfs destroy, deregister
config.rb                   # + add_vm(entry) / remove_vm(name) helpers (mutate @vms, then save)
cli.rb                      # + 'create'/'import'/'destroy' in COMMANDS; usage text updated
```

- `Provisioner.new(executor, defaults)` — `create_dataset(vm)`,
  `create_disk(path, size, from:)`. Pure orchestration over `Executor`.
- `CloudInit.new(executor)` — `build_seed(vm, user_data_path)`: writes meta-data
  + user-data to a temp seed dir and runs `makefs`. Meta-data generation
  (`meta_data_for(name)`) is pure and unit-tested.
- Commands stay thin: parse/validate args, then delegate to domain objects.
- `Config#add_vm`/`#remove_vm` keep inventory mutation in one place so the
  atomic-save invariant is preserved.

## Error handling

- Domain failures raise the project's error types so the CLI rescues them:
  `Commands::CommandError` (bad args, name/link taken, already exists, running),
  `NetgraphError` (missing bridge), `ConfigError`, `ExecutorError` (a failed
  `zfs`/`truncate`/`cp`/`makefs`). The CLI prints `error: …` and exits 1; usage
  errors (`OptionParser::ParseError`) exit 2 — both already wired in Phase 1.
- `create` validates fully **before** provisioning, so a rejected create leaves
  no dataset or files behind. If a `Provisioner` step fails mid-way (e.g.
  `truncate` after `zfs create`), the error surfaces; cleanup of a
  partially-created dataset is the operator's call via `destroy --purge` (a
  documented limitation, not an automatic rollback in Phase 2).

## Testing

No gems; minitest + `test/run_all.rb`, as in Phase 1.

- **Pure logic, fully tested:** disk-list building from defaults + `--disk`
  flags + overrides; `from:`/`image_dir` path resolution; meta-data generation;
  mac resolution (`--mac ADDR` / `generate` / none); the grow-vs-shrink decision.
- **Shell-out boundaries via FakeExecutor:** `Provisioner` emits exactly
  `zfs create tank/bhyve/pod35`, `truncate -s 20G …`, `cp <image> …`;
  `CloudInit` emits the exact `makefs -t cd9660 -o rockridge,label=cidata …`;
  `destroy --purge` emits `zfs destroy tank/bhyve/pod35`.
- **Real-filesystem tests:** `import`'s `*.raw` scan + size read against temp
  files; cloud-init seed-dir contents (meta-data/user-data written correctly)
  before the `makefs` call.
- **Command integration:** `create` happy path registers the expected entry and
  calls the provisioner in order; validation failures (missing bridge, taken
  name/link, existing dataset, missing template/image) raise the right errors and
  write nothing; `--cloud-init` records the `cloud_init` field; `destroy` refuses
  a running VM and (with `--purge`) destroys the dataset; dry-run on each command
  writes nothing and emits the planned actions.

## CLI surface (additions)

```
vmctl create <name>   Allocate + provision a new VM.
    --network NET            (required) netgraph bridge
    --config TMPL            shared config template (default: defaults.template)
    --mac ADDR|generate      pin a MAC, or generate one (default: none)
    --root-size SIZE         override the default root disk size
    --root-from IMAGE        override/ set the root golden image (relative to image_dir)
    --disk SUFFIX:SIZE[:from IMAGE]   add an extra disk (repeatable)
    --cloud-init FILE        build a NoCloud seed ISO from this user-data file
    --autostart              mark the VM autostart
    --start                  boot immediately after create

vmctl import <name>   Adopt an existing (zfs-recv'd) VM's disks as new.
    --network NET            (required)
    --config TMPL            (default: defaults.template)
    --mac ADDR               pin a MAC (default: none)

vmctl destroy <name>  Remove a VM from the inventory.
    --purge                  also zfs-destroy the dataset (disks + seed)
    --yes                    skip the confirmation prompt
```

(All three honor the global `-n/--dry-run` and `-c/--config` flags.)
