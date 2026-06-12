# `create --iso`: installer ISO support — Design

**Date:** 2026-06-12
**Status:** Approved

## Goal

Let `vmctl create` attach an installer ISO (e.g. a FreeBSD or Debian install
CD) to a new VM, so the first boot runs the OS installer against the VM's
blank root disk.

## Approach

Reuse bhyve's config-variable mechanism, exactly as `network`, `link`, and
`mac` work today. An installer-capable template declares the CD device itself
and references a `%(iso)` variable for the media path:

```
pci.0.5.0.device=ahci
pci.0.5.0.port.0.type=cd
pci.0.5.0.port.0.ro=true
pci.0.5.0.port.0.path=%(iso)
```

vmctl supplies the variable at start with `-o iso=<path>`. Templates stay
opaque: the template author owns the PCI slot and device type; vmctl only
fills in the path.

Rejected alternatives:

- **vmctl injects the whole CD device via `-o` flags** — vmctl would have to
  pick a PCI slot blindly, colliding with template-declared devices, and it
  breaks the "templates stay opaque" rule.
- **Fixed-path convention with copy/symlink into the VM dataset** (like the
  cloud-init seed ISO) — copies duplicate multi-GB images per VM; symlinks
  re-create the variable approach with extra dangling-link failure modes.

## Decisions

- **Lifecycle:** `iso:` persists in the VM's inventory entry and is attached
  on every start until removed by hand-editing the inventory. UEFI boot falls
  through naturally: blank disk → CD boots the installer; installed disk →
  boots the OS and the attached ISO is inert. No detach command for now.
- **Storage:** the ISO is referenced in place (e.g. `/bhyve/isos/...`), never
  copied into the VM dataset. `destroy` never touches it. If the ISO is
  deleted from its store, `start` fails validation with a clear error.

## Changes by component

### `lib/vmctl/config.rb`

- `VMEntry` gains an `iso` member.
- `parse_vm` reads `body['iso']`.
- `vm_to_h` emits `'iso'` only when set (same pattern as `cloud_init`).

Inventory entry:

```yaml
vms:
  pod36:
    config: pod-installer.conf
    network: labs_vlan50
    link: 11
    iso: /bhyve/isos/freebsd-14.3.iso
    disks:
      - { file: pod36-root.raw, size: 20G }
```

### `lib/vmctl/vm.rb`

- `bhyve_argv` appends `['-o', "iso=#{entry.iso}"]` when `entry.iso` is set
  (mirrors the existing `mac` conditional). `dump_command` inherits it.
- New helper `template_wants_iso?`: scans the template file for `%(iso)`,
  ignoring commented (`#`) lines, since example templates ship commented-out
  `%(mac)` lines and a naive grep would false-positive.

### `lib/vmctl/commands/create.rb`

- New `--iso FILE` option; the path is expanded to absolute
  (`File.expand_path`) before storing, because bhyve runs detached and a
  relative path would break.
- `build_entry` sets `iso:` on the new `VMEntry`.
- `validate!` additionally checks:
  - the ISO file exists;
  - template/iso cross-validation (below).

### Template cross-validation (create and start)

Two symmetric checks, raised as `CommandError`:

1. VM has `iso:` but its template never references `%(iso)` →
   `template X does not reference %(iso)`.
2. Template references `%(iso)` but the VM has no `iso:` → error, because
   bhyve would receive an empty/unexpanded CD path.

Enforced at both `create` (fail before provisioning) and `start` (inventory
is hand-edited, so the pair can drift after creation).

### `examples/pod-installer.conf`

`pod.conf` plus the `ahci` CD device shown above, with a header comment
explaining the `%(iso)` convention.

### README

- Add `--iso FILE` to the create options.
- Sample command:

```sh
vmctl create pod36 --network labs_vlan50 --config pod-installer.conf \
  --iso /bhyve/isos/freebsd-14.3.iso --start
```

- Note the lifecycle: the ISO stays attached until the `iso:` line is removed
  from the inventory; with UEFI this is harmless after install.

## Out of scope (YAGNI)

- `import --iso`
- A `modify`/detach command
- ISO copying or library management
- Boot-order control

## Error handling

Missing ISO file, missing `%(iso)` in template, and the reverse mismatch all
raise `CommandError`, surfacing through the existing exit-1 path in
`cli.rb`. `destroy` is untouched.

## Testing

Unit specs mirroring the existing suite:

- Config round-trip: entry with and without `iso` (parse + serialize).
- `bhyve_argv` includes `-o iso=<path>` when set, omits it when not.
- `template_wants_iso?`: present, absent, and commented-out `%(iso)`.
- Create: `--iso` parsing, absolute-path expansion, missing-file error, and
  both cross-validation failures.
- Start: cross-validation failures for a hand-edited inventory.
