# vmctl `import --link N` — Design

**Date:** 2026-06-04
**Status:** Approved design, pre-implementation
**Builds on:** Phase 2 (provisioning), on `main`. Extends the existing `import` command.

## Summary

Add an optional `--link N` flag to `vmctl import`. When given, `import` **pins**
that link instead of allocating a fresh one. This is the migration path for
adopting **existing in-place VMs** (started by hand / old scripts) without
changing the link their console (`/dev/nmdm<link>`) and netgraph peerhook
already use.

Without `--link`, behavior is unchanged: allocate the lowest-free link
≥ `link_base` (the zfs-recv'd-onto-a-new-host case).

## Motivation

`import` was built for VMs arriving via `zfs recv` on a *new* host, so it
allocates a fresh link to avoid collisions. But an existing local VM already has
an assigned link baked into its netgraph hook and nmdm console device. Importing
it with a new link would shift those on the next `vmctl start`. `--link` lets the
operator preserve the existing link.

## Behavior

```
vmctl import pod34 --network labs_vlan50 --link 8
```

- `--link N` (Integer): use N as the VM's link.
- **Accepts any *unused* link, including values below `link_base`.** Existing
  VMs may sit in the reserved `0–9` band; the `link_base` floor governs only
  *auto*-allocation, not an explicitly pinned link.
- Validation: if N is already used by another VM in the inventory, raise
  `CommandError` ("link N already in use"). The check uses the existing
  `Allocator#link_taken?(n)`.
- Omitted: `Allocator#next_link` as today (lowest free ≥ `link_base`).

Everything else about `import` is unchanged (scan `<vm_root>/<name>/*.raw`, build
disks with on-disk sizes, register, dry-run guards save, etc.).

## Implementation

In `lib/vmctl/commands/import.rb`:
- Add `p.on('--link N', Integer) { |v| o[:link] = v }` to the option parser.
- Replace the unconditional `Allocator.new(config).next_link` with a small
  resolver:
  ```ruby
  allocator = Allocator.new(config)
  link =
    if opts[:link]
      if allocator.link_taken?(opts[:link])
        raise CommandError, "link #{opts[:link]} already in use"
      end
      opts[:link]
    else
      allocator.next_link
    end
  ```
- Use `link` in the `VMEntry`.

(`OptionParser` coerces `--link N` to Integer and raises `OptionParser::ParseError`
on a non-integer, which the CLI already rescues → exit 2.)

## Error handling

- Non-integer `--link` → `OptionParser::ParseError` → CLI exit 2.
- Taken link → `CommandError` → CLI exit 1.
- (Existing import errors — missing name/network, taken name, missing dataset
  dir, no `*.raw` — unchanged.)

## Testing

- `import --link 8` registers the VM with link 8 even though `link_base` is 10
  (proves the below-base pin is allowed).
- `import --link 10` colliding with an existing VM on link 10 raises
  `CommandError` (/already in use/).
- `import` without `--link` still auto-allocates a fresh link (existing
  `test_import_scans_disks_and_allocates_fresh_link` already covers this).

## Out of scope (YAGNI)

- No `--link` on `create` (create's job is allocation; pin is a rare need, easy
  to add later).
- No reservation/tracking of manually-used links beyond the existing
  collision check.

## Docs

- Add a short "Adopting existing VMs" note to the README pointing at
  `import --link`, since that's the migration story.
