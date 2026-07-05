# vmctl cloud-init fully inventory-driven — Design

**Date:** 2026-07-05
**Status:** Approved design, pre-implementation
**Builds on:** Phases 1–4 + argv-Executor on `main` (through PR #8).

## Summary

Finish making the bhyve config fully inventory-driven, and make cloud-init
user-data **dynamic per VM**. Two threads, bundled:

- **(A) Generate the CD devices.** Move the installer-ISO CD and the cloud-init
  seed CD out of templates into `ConfigRenderer` (the last per-VM device wiring
  still template-owned). This lets us delete the special installer/cloud-init
  example flavors and **remove the now-obsolete `validate_iso_pairing!` /
  `template_wants_iso?`** — templates become pure OS-core.
- **(B) Dynamic user-data.** The `cloud_init` inventory entry carries a
  **template** (shareable) plus a per-VM **`vars`** map; `CloudInit` substitutes
  `%()` placeholders into the template before packing the NoCloud seed. Add
  `--var` to `create`/`set` and `set --cloud-init` / `--no-cloud-init`.

`instance-id` stays `= <vm name>` (stable): editing user-data updates the seed but
a provisioned guest re-applies only on a fresh provision (predictable; no
surprise `runcmd` re-runs). No new gem dependencies.

## Part A — generate the CD devices

### `ConfigRenderer` generators

`GENERATORS` becomes `[disk_keys, net_keys, iso_cd_keys, seed_cd_keys]`. Each new
generator emits keys only when its inventory field is set:

- **`iso_cd_keys(vm)`** — when `entry.iso`:
  ```
  pci.0.5.0.device=ahci
  pci.0.5.0.port.0.type=cd
  pci.0.5.0.port.0.ro=true
  pci.0.5.0.port.0.path=<entry.iso>
  ```
- **`seed_cd_keys(vm)`** — when `entry.cloud_init`:
  ```
  pci.0.6.0.device=ahci
  pci.0.6.0.port.0.type=cd
  pci.0.6.0.port.0.path=<vm.dir>/<name>-seed.iso
  ```

Distinct slots (`pci.0.5` installer, `pci.0.6` seed) so a VM may carry both. The
installer CD keeps `ro=true` (matching the old installer flavor); the seed CD is
read-write like the old cloud-init flavor.

### Remove the pairing machinery

With the iso CD generated whenever `iso:` is set, the template no longer declares
`%(iso)`, so `validate_iso_pairing!` (in `Commands::Base`) and
`VM#template_wants_iso?` are obsolete. **Remove both**, their calls in
`create`/`start`/`set`, and their tests. A VM with `iso:` now works on *any* base
flavor.

### Shared substitution helper

Extract the `%()` substitution `ConfigRenderer` does privately into a small shared
`VMCtl.substitute(text, vars)` (new `lib/vmctl/substitution.rb`) so both
`ConfigRenderer` and `CloudInit` (Part B) share one semantics:

```ruby
module VMCtl
  # Replace %(word) tokens from vars (string keys); unknown tokens pass through.
  def self.substitute(text, vars)
    text.gsub(/%\((\w+)\)/) { vars.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
  end
end
```

`ConfigRenderer#substitute` becomes a thin caller passing
`{name, network, link, mac, iso}` — behavior unchanged (regression-guarded by the
existing byte-identical-primary tests).

## Part B — dynamic user-data

### Inventory schema

```yaml
cloud_init:
  user_data: web-base.yml     # a TEMPLATE (resolved in config_dir, or an absolute path)
  vars:                       # optional per-VM substitution values
    role: web
    admin_key: "ssh-ed25519 AAAA... you@host"
```

`cloud_init` stays a Hash (minimal churn). `parse_cloud_init` validates: when
present, `user_data` is a non-empty String and `vars` (optional) is a mapping →
else `ConfigError`. `vm_to_h` continues to emit `cloud_init` only when set.

### `CloudInit` rendering

`CloudInit#build_seed(vm, template_path, vars)` now **renders** rather than copies:

1. `render_user_data(vm, text, vars)` — a **public, pure** method:
   `VMCtl.substitute(text, builtins(vm).merge(stringify(vars)))`, built-ins
   `{name, network, link, mac}`; operator `vars` win on key collision. This is
   the observable/testable seam (no side effects).
2. `build_seed` reads the template, calls `render_user_data`, writes `meta-data`
   (unchanged: `instance-id`/`local-hostname = name`) + the rendered user-data
   into an ephemeral seed dir, and `makefs` → `<vm.dir>/<name>-seed.iso`.

No rendered copy is written to `<vm.dir>` (keeps `build_seed` free of a `vm.dir`
write, which the create/set command tests can't provide — the dataset dir must
not pre-exist for `create`). Inspect rendered output via `render_user_data` or by
mounting the seed. `meta_data_for` is unchanged. Template resolution: absolute
path used as-is, else `File.join(defaults.config_dir, user_data)`.

### Seed lifecycle

The **seed ISO is a build artifact** rebuilt by the commands that change
cloud-init (`create`, `set`) — **not** per-start (`makefs` is a side effect, and a
stable `instance-id` means a per-start rebuild wouldn't re-apply anyway). The seed
**CD device** is generated into the ephemeral config every start (Part A),
pointing at the file.

### CLI

- **`create --cloud-init <template> [--var K=V]…`** — template resolved in
  `config_dir`; `--var` repeatable → `vars`. Validates the template exists; builds
  the seed; sets `entry.cloud_init = { 'user_data' => <template>, 'vars' => vars }`
  (omitting `vars` when empty). Drops the old verbatim-copy path and the
  `validate_iso_pairing!` call.
- **`set --cloud-init <template> [--var K=V]…`** — change template and/or vars and
  **rebuild the seed**. `set --var K=V` alone (on a VM that already has
  cloud-init) updates a var and rebuilds. `set --no-cloud-init` → `entry.cloud_init
  = nil` (the seed CD then stops generating); leaves the seed file on disk.
  ⚙️ Validates the template exists when setting one.
- `--var K=V` splits on the first `=`; `K` must match `\A\w+\z` (a valid `%(K)`
  token) else `CommandError`.

## Migration

- Delete `examples/pod-installer.conf` and `examples/pod-cloudinit.conf` — with
  CDs generated they'd equal `pod.conf`. Update `pod.conf`'s header (CDs are now
  generated from `iso:`/`cloud_init:` too), the README, and the example inventory
  (a cloud-init VM with `vars`, and an `iso:` VM — both on the plain `pod.conf`).
- Existing `cloud_init.user_data` now resolves as a `config_dir` template (or
  absolute path) rather than a per-VM `vm.dir` copy. Pre-1.0 clean break;
  documented. A deployed VM whose `config:` points at a now-deleted installer/
  cloud-init flavor must switch to `pod.conf`.

## Error handling

- Missing template file (`create`/`set`) → `CommandError`.
- Bad `--var` (`no =`, or key not `\w+`) → `CommandError`.
- Malformed `cloud_init` (`user_data` missing/blank, `vars` non-mapping) →
  `ConfigError` at load.
- `makefs` failure → `ExecutorError` (unchanged).

## Testing

- **`VMCtl.substitute`** (unit): token replace, unknown-token passthrough,
  non-ASCII tolerance.
- **`ConfigRenderer`**: `iso_cd_keys` present/absent (slot `pci.0.5`, `ro=true`);
  `seed_cd_keys` present/absent (slot `pci.0.6`, seed path); both-at-once (no
  collision); existing byte-identical-primary/disk/net tests still green after the
  `substitute` extraction.
- **`CloudInit`**: renders built-ins + vars; vars win; template with no vars;
  meta-data unchanged; missing template errors; the rendered copy + seed path.
- **`Config`**: `cloud_init` parse/round-trip with `vars`; malformed raises.
- **Commands**: `create --cloud-init --var` (seed built, entry recorded);
  `set --cloud-init`/`--var` (seed rebuilt, round-trip); `set --no-cloud-init`
  (field cleared, seed CD gone from `dump`); removal of the old iso-pairing tests;
  `create`/`start` no longer probe `%(iso)` pairing.
- **`VM`**: `template_wants_iso?` removed (delete its tests).
- **Migration**: rendering an `iso:` VM and a `cloud_init:` VM on the plain
  `pod.conf` flavor produces the expected `pci.0.5`/`pci.0.6` CD blocks.

## Implementation phasing

The plan lands in two green phases:

- **Phase A** — shared `substitute` helper; `iso_cd_keys`/`seed_cd_keys`
  generators; remove pairing machinery; migrate examples/README. Cloud-init still
  builds the seed verbatim (Part B not yet). Suite green.
- **Phase B** — `CloudInit` rendering (template + vars); `parse_cloud_init`;
  `create`/`set` `--cloud-init`/`--var`/`--no-cloud-init`; seed rebuild. Suite
  green.

## Out of scope (YAGNI)

- Structured cloud-init generation (vmctl modelling users/packages/runcmd) —
  templates keep cloud-init's full expressiveness; vmctl never parses cloud-init
  semantics.
- Content-derived / bumped `instance-id` (re-apply on change) — stable only.
- Per-start seed rebuild.
- cloud-init **network-config** generation (static in-guest IPs) — vmctl does not
  track guest IPs; a future feature if ever needed.
- A standalone `rebuild-seed` command — `set --cloud-init <same>` rebuilds.
