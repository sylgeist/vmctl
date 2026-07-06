# SMBIOS Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global `defaults.smbios` map plus an optional per-VM `smbios` map that inject bhyve SMBIOS keys (`bios.*`/`system.*`/`board.*`/`chassis.*`) into every VM's rendered config.

**Architecture:** SMBIOS is a static render layer (not a device generator): in `ConfigRenderer#resolve` the global `defaults.smbios` map and then the per-VM `vm.smbios` map are merged over the template and before the per-VM `options:` map. Both levels share one `parse_smbios` validator that enforces the four SMBIOS key namespaces.

**Tech Stack:** Pure Ruby (stdlib only, no gems). minitest. Module namespace `VMCtl`.

## Global Constraints

- **Ruby stdlib only** — no gems, ever.
- **Run the full suite with:** `ruby -Ilib -Itest test/run_all.rb` (from repo root).
- **Run one test file with:** `ruby -Ilib -Itest test/<file>.rb`; one method/pattern with `-n "/pattern/"`.
- **Module namespace:** `VMCtl`. Structs use `keyword_init: true`; new members appended at the END of the member list.
- **Render layering (broadest → narrowest):** `template < defaults.smbios < vm.smbios < options: < generators`.
- **SMBIOS key namespaces (the ONLY allowed key prefixes):** `bios.`, `system.`, `board.`, `chassis.`. Any other prefix → `ConfigError` at load, at BOTH the defaults and per-VM levels.
- **Values are stringified** (`to_s`), so `bios.version: 14.0` (YAML float) → `"14.0"`.
- **Both `smbios` maps default to `{}`** and are omitted from `to_h`/`vm_to_h` when empty (existing inventories stay byte-stable; no rendered-config change unless a VM/defaults sets SMBIOS).
- **No CLI.** SMBIOS is edited directly in the inventory YAML.
- **Commit after each task** once its tests pass. git writes in this repo are sandbox-denied — set `dangerouslyDisableSandbox: true` on the commit Bash call. Commit trailer (blank line before it):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tw1uWUsKMXsnLErXaGuHRq
  ```

## File Structure

- `lib/vmctl/config.rb` — `smbios` on `Defaults` + `VMEntry` + `DEFAULTS`; `parse_smbios` validator; parse + round-trip. (Task 1)
- `lib/vmctl/config_renderer.rb` — two inserted layer lines in `resolve`. (Task 2)
- `README.md`, `examples/inventory.yml` — document both levels. (Task 3)
- Tests: `test/test_config.rb`, `test/test_config_renderer.rb`.

---

### Task 1: Schema — `smbios` on Defaults + VMEntry, with `parse_smbios` validator

**Files:**
- Modify: `lib/vmctl/config.rb`
- Test: `test/test_config.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Defaults#smbios` — Hash (default `{}`), String keys/values.
  - `VMEntry#smbios` — Hash (default `{}`), String keys/values.
  - Both validated to the four SMBIOS namespaces; a bad prefix raises `ConfigError`.
  - `to_h`/`vm_to_h` emit `smbios` only when non-empty.

- [ ] **Step 1: Write the failing tests**

Add to `class TestConfig` in `test/test_config.rb`:

```ruby
  def test_defaults_smbios_parsed_and_stringified
    f = write_inventory(<<~YAML)
      defaults:
        smbios:
          system.manufacturer: MyLab
          bios.version: 14.0
      vms: {}
    YAML
    cfg = VMCtl::Config.load(f.path)
    assert_equal({ 'system.manufacturer' => 'MyLab', 'bios.version' => '14.0' },
                 cfg.defaults.smbios)
    f.close
  end

  def test_defaults_smbios_absent_is_empty
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal({}, cfg.defaults.smbios)
    f.close
  end

  def test_smbios_rejects_non_mapping
    f = write_inventory("defaults: { smbios: nope }\nvms: {}\n")
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_defaults_smbios_rejects_bad_namespace
    f = write_inventory(<<~YAML)
      defaults:
        smbios:
          pci.0.3.0.path: /evil
      vms: {}
    YAML
    err = assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    assert_match(/invalid smbios key/, err.message)
    f.close
  end

  def test_vm_smbios_parsed_and_bad_namespace_rejected
    ok = write_inventory(<<~YAML)
      vms:
        a: { network: n, link: 10, smbios: { system.serial_number: POD34-001 } }
    YAML
    cfg = VMCtl::Config.load(ok.path)
    assert_equal({ 'system.serial_number' => 'POD34-001' }, cfg.vms.fetch('a').smbios)
    ok.close

    bad = write_inventory(<<~YAML)
      vms:
        a: { network: n, link: 10, smbios: { foo.bar: x } }
    YAML
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(bad.path) }
    bad.close
  end

  def test_vm_smbios_absent_is_empty
    f = write_inventory("vms:\n  a: { network: n, link: 10 }\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal({}, cfg.vms.fetch('a').smbios)
    f.close
  end

  def test_smbios_round_trip
    f = write_inventory(<<~YAML)
      defaults:
        smbios: { system.manufacturer: MyLab }
      vms:
        a: { network: n, link: 10, smbios: { system.serial_number: S1 }, disks: [] }
        b: { network: n, link: 11, disks: [] }
    YAML
    cfg = VMCtl::Config.load(f.path)
    h = cfg.to_h
    assert_equal({ 'system.manufacturer' => 'MyLab' }, h['defaults']['smbios'])
    assert_equal({ 'system.serial_number' => 'S1' }, h['vms']['a']['smbios'])
    refute h['vms']['b'].key?('smbios'), 'empty per-VM smbios omitted'
    f.close
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/smbios/"`
Expected: FAIL (`NoMethodError: undefined method 'smbios'` / assertions fail).

- [ ] **Step 3: Implement the schema changes**

In `lib/vmctl/config.rb`:

Append `:smbios` to the `Defaults` struct member list (after `:rtc_localtime`):

```ruby
  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from, :cpus, :memory, :vnc_base, :vnc_bind,
    :uefi_vars_template, :rtc_localtime, :smbios,
    keyword_init: true
  )
```

Append `:smbios` to the `VMEntry` struct member list (after `:memory_wired`):

```ruby
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options, :mtu, :networks, :cpus, :memory, :graphics, :efi_vars,
    :rtc_localtime, :memory_wired, :smbios,
    keyword_init: true
  )
```

Add to `DEFAULTS` (after the `rtc_localtime` entry):

```ruby
      'rtc_localtime' => true,
      'smbios' => {}
```

Add the namespace constant inside `class Config` (near `DEFAULTS`):

```ruby
    SMBIOS_PREFIXES = %w[bios. system. board. chassis.].freeze
```

In `parse_defaults`, add to the `Defaults.new(...)` call (after `rtc_localtime:`):

```ruby
        rtc_localtime: merged['rtc_localtime'],
        smbios: parse_smbios(merged['smbios'])
```

In `parse_vm`, add to the `VMEntry.new(...)` call (after `memory_wired:`):

```ruby
        memory_wired:  body.fetch('memory_wired', false),
        smbios:        parse_smbios(body['smbios'])
```

Add the `parse_smbios` helper (place near `parse_options`):

```ruby
    def parse_smbios(v)
      return {} if v.nil?
      raise ConfigError, "'smbios' must be a mapping" unless v.is_a?(Hash)
      v.each_with_object({}) do |(k, val), h|
        key = k.to_s
        unless SMBIOS_PREFIXES.any? { |p| key.start_with?(p) }
          raise ConfigError,
                "invalid smbios key '#{key}' (must be one of bios./system./board./chassis.*)"
        end
        h[key] = val.to_s
      end
    end
```

In `vm_to_h`, emit the per-VM map only when non-empty (add after the `memory_wired` line):

```ruby
      h['memory_wired'] = true if vm.memory_wired
      h['smbios'] = vm.smbios unless vm.smbios.nil? || vm.smbios.empty?
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/smbios/"`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green. (Trailing struct members are backward-compatible; `DEFAULTS['smbios'] = {}` equals a parsed-empty default so `to_h` still omits it — byte-stable.)

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "feat(config): global + per-VM smbios maps with namespace validation"
```

---

### Task 2: Renderer — inject the SMBIOS layers in `resolve`

**Files:**
- Modify: `lib/vmctl/config_renderer.rb`
- Test: `test/test_config_renderer.rb`

**Interfaces:**
- Consumes: `Defaults#smbios`, `VMEntry#smbios` (Task 1).
- Produces: SMBIOS keys in the resolved map, layered `defaults.smbios` then `vm.smbios` then `options:`.

- [ ] **Step 1: Update test helpers, then write failing tests**

**1a.** In `test/test_config_renderer.rb`, extend the `entry` helper to accept `smbios:` (default `{}`) and pass it through:

```ruby
  def entry(disks:, mac: nil, iso: nil, cloud_init: nil, options: {}, config: 'base.conf',
            network: 'labs_vlan50', mtu: nil, networks: [], cpus: nil, memory: nil,
            graphics: false, efi_vars: false, rtc_localtime: nil, memory_wired: false,
            smbios: {})
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: network, link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: cloud_init, iso: iso,
      options: options, mtu: mtu, networks: networks, cpus: cpus, memory: memory,
      graphics: graphics, efi_vars: efi_vars, rtc_localtime: rtc_localtime,
      memory_wired: memory_wired, smbios: smbios
    )
  end
```

**1b.** Extend the `defaults` helper to accept `smbios:` (default `{}`), adding it to its `Defaults.new(...)`:

```ruby
  def defaults(config_dir, smbios: {})
    VMCtl::Defaults.new(
      config_dir: config_dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'base.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl',
      cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0',
      rtc_localtime: true, smbios: smbios
    )
  end
```

**1c.** Update the `render` helper to thread `smbios:` and build the `Defaults` once:

```ruby
  def render(flavor_body, e, smbios: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, e.config), flavor_body)
      d = defaults(dir, smbios: smbios)
      return VMCtl::ConfigRenderer.new(d).render(VMCtl::VM.new(e, d))
    end
  end
```

**1d.** Add renderer tests:

```ruby
  def test_defaults_smbios_emitted
    out = render("cpus=2\n", entry(disks: []), smbios: { 'system.manufacturer' => 'MyLab' })
    assert_match(/^system\.manufacturer=MyLab$/, out)
  end

  def test_no_smbios_no_keys
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/^system\./, out)
    refute_match(/^bios\./, out)
  end

  def test_vm_smbios_overrides_defaults_smbios
    out = render("cpus=2\n",
                 entry(disks: [], smbios: { 'system.manufacturer' => 'PerVM' }),
                 smbios: { 'system.manufacturer' => 'MyLab' })
    assert_match(/^system\.manufacturer=PerVM$/, out)
    refute_match(/^system\.manufacturer=MyLab$/, out)
  end

  def test_options_overrides_smbios
    out = render("cpus=2\n",
                 entry(disks: [], smbios: { 'system.manufacturer' => 'S' },
                       options: { 'system.manufacturer' => 'O' }))
    assert_match(/^system\.manufacturer=O$/, out)
    refute_match(/^system\.manufacturer=S$/, out)
  end

  def test_defaults_smbios_overrides_template
    out = render("system.manufacturer=TPL\n", entry(disks: []),
                 smbios: { 'system.manufacturer' => 'MyLab' })
    assert_match(/^system\.manufacturer=MyLab$/, out)
    refute_match(/^system\.manufacturer=TPL$/, out)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/smbios/"`
Expected: FAIL (SMBIOS keys not emitted; template value not overridden).

- [ ] **Step 3: Implement the layers**

In `lib/vmctl/config_renderer.rb`, insert two lines in `resolve`, after the template parse and **before** the `options:` merge:

```ruby
    def resolve(vm)
      text = File.binread(vm.template_path)
      map = parse_pairs(substitute(text, vm.entry))
      stringify(@defaults.smbios).each { |k, v| map[k] = v }   # global SMBIOS identity
      stringify(vm.entry.smbios).each  { |k, v| map[k] = v }   # per-VM SMBIOS (beats global)
      stringify(vm.entry.options).each { |k, v| map[k] = v }
      generators.each { |gen| gen.call(vm).each { |k, v| map[k] = v } }
      map
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/smbios/"`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green. (`stringify` tolerates nil/empty, so VMs without SMBIOS emit nothing new; existing exact-output tests are unaffected.)

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/config_renderer.rb test/test_config_renderer.rb
git commit -m "feat(renderer): inject global + per-VM SMBIOS layers into resolve"
```

---

### Task 3: Docs — README + example inventory

**Files:**
- Modify: `README.md`, `examples/inventory.yml`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Document in the example inventory**

Read `examples/inventory.yml` first and match its style. Under `defaults:` (after the `rtc_localtime` line), add a `smbios:` block, e.g.:

```yaml
  # smbios:                      # SMBIOS identity applied to every VM (bhyve keys)
  #   system.manufacturer: MyLab
  #   system.product_name: pod
  #   board.manufacturer: MyLab
  #   chassis.manufacturer: MyLab
```

Add a commented per-VM example to one existing VM entry:

```yaml
    # smbios:                    # per-VM SMBIOS overrides/additions (beats defaults.smbios)
    #   system.serial_number: POD34-001
    #   chassis.asset_tag: rack3-u12
```

Do not restructure the file or change unrelated lines. (Commented so the example inventory still loads with an empty SMBIOS by default.)

- [ ] **Step 2: Document in the README**

Read `README.md` first (the generated/inventory-fields section). Add a bullet:

- **SMBIOS identity** (`bios.*`/`system.*`/`board.*`/`chassis.*`) — `defaults.smbios` is a flat map of bhyve SMBIOS keys applied to every VM (consistent homelab hardware identity: manufacturer, product name, etc.). A per-VM `smbios:` map overrides or adds keys for a single VM (e.g. a unique `system.serial_number` / `chassis.asset_tag`). Keys must be in the `bios.`/`system.`/`board.`/`chassis.` namespaces. Layering: `defaults.smbios` < per-VM `smbios` < per-VM `options:`. Edited in the inventory YAML (no CLI).

Match the README's existing heading level and prose style; do not restructure existing sections.

- [ ] **Step 3: Run the full suite (docs shouldn't affect it; confirm)**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add README.md examples/inventory.yml
git commit -m "docs: document global + per-VM SMBIOS identity"
```

---

## Self-Review

**Spec coverage:**
- `Defaults#smbios` + `VMEntry#smbios` (default `{}`) + `DEFAULTS['smbios']` → Task 1. ✓
- Shared `parse_smbios` validator (mapping check + namespace guard + stringify) used at both levels → Task 1. ✓
- `to_h`/`vm_to_h` emit smbios only when non-empty (byte-stable) → Task 1. ✓
- `ConfigError` on non-mapping and bad-namespace at both levels → Task 1 tests. ✓
- Renderer layering `template < defaults.smbios < vm.smbios < options: < generators` → Task 2 (line order in `resolve` + the four override tests). ✓
- No CLI → omitted by design (constraint). ✓
- No migration; byte-stable → constraints + Task 1 Step 5. ✓
- README + example inventory (both levels) → Task 3. ✓

**Placeholder scan:** No TBD/TODO. Task 3 says "read the file and match style" because the README/example structure isn't reproduced, but the required content (both levels, namespaces, layering, no-CLI) is fully enumerated.

**Type consistency:** `smbios` is a `Hash` of String→String everywhere. `parse_smbios(v)` returns `{}` for nil and a new stringified Hash otherwise; used identically in `parse_defaults` (`merged['smbios']`) and `parse_vm` (`body['smbios']`). `SMBIOS_PREFIXES` is the single source of the namespace list. Renderer reads `@defaults.smbios` and `vm.entry.smbios` (both provided by Task 1) and merges them via the existing `stringify` before `options:`. Test helpers thread `smbios:` through `entry`/`defaults`/`render` consistently.
