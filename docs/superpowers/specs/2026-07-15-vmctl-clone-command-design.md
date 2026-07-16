# vmctl `clone` command — design

**Date:** 2026-07-15
**Status:** Approved (brainstorm) — pending implementation plan

## Summary

Add a `vmctl clone <source> <newname>` command that provisions a new VM as an
independent copy of an existing one. The intended use case is treating a
powered-off, hand-tuned VM as a "golden template" and stamping fresh VMs from
it — but any VM in the inventory can be a clone source; there is no separate
"template" concept.

The clone's disks are a **full independent copy** of the source's ZFS dataset
(`zfs snapshot` + `zfs send | zfs recv`), so the clone and source have no
lasting ZFS dependency: either can be `zfs destroy`ed later with the existing
`destroy` lifecycle, unchanged.

## Motivation

`create` builds a VM from a golden image + template; `import` adopts a dataset
that already exists on disk. Neither lets you say "make another one like *that*
VM." Cloning a configured VM (packages installed, config applied) is faster than
re-provisioning from a base image and is the natural homelab workflow for
standing up near-identical VMs.

## Command surface

```
vmctl clone <source> <newname> [options]

  --network NET     Place the clone on NET (default: inherit source's bridge)
  --mac MAC         Override the clone's primary MAC (default: fresh — see below)
  --cpus N          Override inherited vCPU count
  --memory SIZE     Override inherited memory (Sizes format, e.g. 8G/512M)
  --autostart       Set autostart:true on the clone (default: off)
  --force           Allow cloning a running source (crash-consistent snapshot)
  --start           Start the clone after it is created
```

- Two positional args: `source` (must exist in the inventory) and `newname`.
- Honors global `-n/--dry-run` and `-c/--config`.
- Registered in `CLI::COMMANDS` as `'clone' => Commands::Clone`, alongside
  `create`/`import`.

## Inherit / reset policy

Everything the clone needs is derivable from the **source's inventory entry** —
no filesystem scan of the source dataset is required. This keeps `--dry-run`
fully accurate.

| Fresh (never copied from source)              | Inherited from source                       |
| --------------------------------------------- | ------------------------------------------- |
| `name` — the `newname` positional arg         | `config` (template)                         |
| `link` — `Allocator#next_link`                | `cpus`, `memory`                            |
| `mac` — regenerated (see below)               | `graphics`, `efi_vars`, `rtc_localtime`     |
| `autostart` — `false` unless `--autostart`    | `memory_wired`, `smbios`                    |
| `disks` — renamed (see ZFS section)           | `cloud_init`                                |
| `network` — inherited unless `--network`      | additional `networks:`, `mtu`               |

### MAC handling

- If the source's primary `mac` is `nil` (bhyve auto-MAC) → the clone's `mac`
  stays `nil`.
- Otherwise → the clone gets a fresh deterministic MAC,
  `Allocator#generate_mac(newname)`.
- Each additional NIC in the source's `networks:` list is regenerated the same
  way, seeded per-index (`generate_mac(newname, index)`); an additional NIC
  whose `mac` was `nil` stays `nil`.
- `--mac` overrides the primary MAC only.

This guarantees the clone never shares a MAC with its source on a common bridge.

### Explicitly dropped

- **`iso:`** — an installer ISO is meaningless on an already-provisioned disk,
  so it is not carried onto the clone.

### Explicitly not preserved

- **UEFI variable store** (`<name>-uefi-vars.fd`) — not carried onto the clone.
  If the source had `efi_vars: true`, the clone keeps `efi_vars: true` in its
  entry, and a pristine vars store is regenerated on the clone's first start
  (existing `efi_vars` behavior). Under UEFI the installed disk boots first, so
  boot order re-derives without the source's saved vars. This avoids probing for
  an optional file that may or may not exist yet.

## ZFS mechanism and disk renaming

For `clone pod34 web1` (zpool `tank/bhyve`, vm_root `/bhyve`):

1. **Snapshot the source:**
   `zfs snapshot tank/bhyve/pod34@vmctl-clone-web1`
2. **Send | recv into the new dataset:**
   `zfs send tank/bhyve/pod34@vmctl-clone-web1 | zfs recv tank/bhyve/web1`
   via a new `Executor#pipe(argv1, argv2)` helper (below).
3. **Rename disk files** inside the new dataset from the source's name-prefix to
   the clone's: `/bhyve/web1/pod34-root.raw → /bhyve/web1/web1-root.raw`, for
   each source disk. The suffix is derived by stripping the leading
   `<sourcename>-` prefix; a disk file **not** prefixed with `<sourcename>-`
   (e.g. an oddly-named imported disk) is left as-is (still isolated in the
   clone's own dataset directory). The new `disks:` list is computed from
   `source.disks`, so no disk scan is needed and dry-run stays accurate.
4. **Remove the copied UEFI vars store (best effort):**
   `rm -f /bhyve/web1/pod34-uefi-vars.fd` — after `recv` this file arrived under
   the *source* name (`<source>-uefi-vars.fd`); we do not rename it (unlike
   disks) and do not want to carry the source's saved vars. `rm -f` is
   idempotent (harmless if the source never had one). The clone regenerates its
   own pristine `web1-uefi-vars.fd` on first start when `efi_vars: true`.
5. **Clean up snapshots:** destroy both the source snapshot
   (`tank/bhyve/pod34@vmctl-clone-web1`) and the snapshot carried into the
   received dataset (`tank/bhyve/web1@vmctl-clone-web1`), leaving a fully
   independent clone dataset with no snapshots.

### `Executor#pipe`

`Open3.capture3` cannot express a pipe without a shell string. Add:

```ruby
# Run argv1 | argv2, no shell. Raises ExecutorError on any non-zero stage.
# No-op (logs only) in dry-run, returning "".
def pipe(argv1, argv2)
  ...  # Open3.pipeline, check every status
end
```

This preserves the "argv, never a shell string" safety property the executor
guarantees today.

## Error handling and atomicity

All validation happens **before** any ZFS operation:

- source name exists in the inventory (else `CommandError: unknown VM`);
- source is stopped, unless `--force` (`vm.running?(executor)`);
- `newname` is a valid, not-already-present inventory key;
- the clone's target dataset dir does not already exist;
- the resolved network's bridge(s) exist (`Netgraph#ensure_bridge!`), same as
  `create`.

If any step from snapshot onward fails, best-effort roll back — destroy the
received dataset (if it was created) and the source snapshot — then re-raise.
The inventory is saved **only** after every ZFS/rename/cleanup step succeeds, so
a failure never leaves a half-registered VM. With `--force` on a running
source, print a warning that the snapshot is crash-consistent.

`--start` reuses `Commands::Start` exactly as `create` does.

## Code structure

- **New file** `lib/vmctl/commands/clone.rb` — `Commands::Clone < Base`.
  Parses args, validates, orchestrates the ZFS steps through `Provisioner`,
  builds the `VMEntry`, saves the inventory, optionally starts. Mirrors
  `create.rb`'s shape.
- **`lib/vmctl/provisioner.rb`** — add a `clone_dataset(source_vm, dest_vm)`
  method encapsulating snapshot → send|recv → rename disks → rm uefi → snapshot
  cleanup, plus rollback on failure. Keeps ZFS mechanics out of the command,
  consistent with how `create_dataset`/`create_disk` live here today.
- **`lib/vmctl/executor.rb`** — add `#pipe` (above).
- **`lib/vmctl/cli.rb`** — register `'clone'`.
- **`README.md`** — document `clone` under Provisioning.

Reused as-is: `Allocator` (link + MAC), `Netgraph` (bridge validation),
`VMEntry`/`Disk` structs, `Start`.

## Testing

New `test/test_clone_command.rb` following `test/test_create_command.rb`, using
`FakeExecutor` to assert the exact command sequence and covering:

- **Command sequence:** snapshot → `pipe(zfs send, zfs recv)` → disk `mv`(s) →
  `rm -f` uefi → snapshot cleanup (source + received).
- **Inheritance:** `cpus`, `memory`, `graphics`, `efi_vars`, `rtc_localtime`,
  `memory_wired`, `smbios`, `cloud_init`, additional `networks:` carried onto
  the clone; `iso:` dropped.
- **Identity freshness:** `link` is the next free link; primary `mac`
  regenerated when the source had one, `nil` when the source's was `nil`;
  `--mac` override; additional-NIC macs regenerated per index.
- **Disk renaming:** `<src>-<suffix>.raw → <new>-<suffix>.raw`; a
  non-`<src>-`-prefixed disk file left unchanged.
- **Network:** inherits source bridge by default; `--network` overrides.
- **Guards:** refuses a running source without `--force`, allows with `--force`;
  refuses unknown source, duplicate `newname`, and an existing target dir.
- **Dry-run:** inventory is not saved; all commands are logged, none executed.
- **`--start`:** invokes `Commands::Start` for the new VM.

Plus an `Executor#pipe` unit test (success passes stdout through; a non-zero
stage raises `ExecutorError`).

## Out of scope

- Machine-readable (`--json`) output for `list`/`status`/`info` — tracked
  separately as its own small change.
- CoW (`zfs clone`) sources and cross-host clone/migration.
- A dedicated `template: true` inventory flag or template protections.
