# UEFI Firmware Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a start-time bootrom-presence check and an opt-in per-VM persistent UEFI variables store (`efi_vars: true` → `bootvars=`), both driven from the inventory.

**Architecture:** Split `ConfigRenderer#render` into `resolve` (key map) + `serialize` (string) so `start` can read the resolved `bootrom` path without re-rendering, then check the file exists. Add an opt-in `efi_vars` boolean that a new `firmware_keys` generator turns into a `bootvars=<per-VM file>` key; the vars file is lazily provisioned at start (copied from a pristine host template when missing), and reset-to-factory is "remove the file" (recreated next start).

**Tech Stack:** Pure Ruby (stdlib only, no gems). minitest. Module namespace `VMCtl`.

## Global Constraints

- **Ruby stdlib only** — no gems, ever.
- **Run the full suite with:** `ruby -Ilib -Itest test/run_all.rb` (from repo root).
- **Run one test file with:** `ruby -Ilib -Itest test/<file>.rb`; one method/pattern with `-n "/pattern/"`.
- **Module namespace:** `VMCtl`. Structs use `keyword_init: true`; new members are appended at the END of the member list (backward-compatible with positional `.new`).
- **Generated keys win** — generators run last in `ConfigRenderer#resolve`, overriding the flavor file and the `options:` map.
- **The executor is argv-based and testable:** existence checks use `executor.success?('test', '-e', path)`; `FakeExecutor` returns `true` for any probe not listed, and matches a probe key as a substring of `argv.join(' ')`. File mutations use `executor.run('cp', ...)` / `executor.run('rm', ...)` and are recorded in `exec.runs` as argv arrays.
- **`efi_vars` default = `false`; `uefi_vars_template` default = `/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd`.**
- **Per-VM vars file path = `<vm_root>/<name>/<name>-uefi-vars.fd`** (in the dataset dir; wiped by `destroy --purge`).
- **`efi_vars`/bootrom fields are omitted from `vm_to_h` when false/absent** (existing inventories stay byte-stable).
- **`bootrom` check and vars provisioning are hard errors** (`CommandError`) at start; both are skipped in `--dry-run` (start returns early before preflight).
- **Commit after each task** once its tests pass. git writes in this repo are sandbox-denied — set `dangerouslyDisableSandbox: true` on the commit Bash call. Commit trailer (blank line before it):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tw1uWUsKMXsnLErXaGuHRq
  ```

## File Structure

- `lib/vmctl/config_renderer.rb` — split `render` into `resolve`/`serialize`; add `firmware_keys` generator. (Tasks 1, 4)
- `lib/vmctl/vm.rb` — add `resolved_config` (memoized map), reuse it in `render_config`; add `uefi_vars_path`. (Tasks 1, 4)
- `lib/vmctl/commands/start.rb` — bootrom check + lazy vars provisioning in preflight. (Tasks 2, 5)
- `lib/vmctl/config.rb` — `efi_vars` on `VMEntry`; `uefi_vars_template` on `Defaults`+`DEFAULTS`; parse + round-trip. (Task 3)
- `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/set.rb`, `lib/vmctl/cli.rb` — `--efi-vars` / `--no-efi-vars` / `--reset-efi-vars` + usage. (Task 6)
- `README.md`, `examples/inventory.yml` — document both parts. (Task 7)
- Tests: `test/test_config_renderer.rb`, `test/test_vm.rb`, `test/test_commands.rb`, `test/test_config.rb`, `test/test_create_command.rb`, `test/test_set_command.rb`.

---

### Task 1: Renderer `resolve`/`serialize` split + `VM#resolved_config`

**Files:**
- Modify: `lib/vmctl/config_renderer.rb` (`render` → `resolve` + `serialize`)
- Modify: `lib/vmctl/vm.rb` (`resolved_config`, `render_config`)
- Test: `test/test_config_renderer.rb`, `test/test_vm.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `ConfigRenderer#resolve(vm) → Hash` (the merged/generated key→value map, all String values).
  - `ConfigRenderer#serialize(map) → String` (`map.sort` joined as `k=v\n`).
  - `ConfigRenderer#render(vm) → String` (unchanged output; now `serialize(resolve(vm))`).
  - `VM#resolved_config → Hash` (memoized `ConfigRenderer.new(@defaults).resolve(self)`).

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config_renderer.rb` (inside `class TestConfigRenderer`):

```ruby
  def test_resolve_returns_key_map
    e = entry(disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)])
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, e.config), "bootrom=/fw/X.fd\ncpus=9\n")
      d = defaults(dir)
      map = VMCtl::ConfigRenderer.new(d).resolve(VMCtl::VM.new(e, d))
      assert_instance_of Hash, map
      assert_equal '/fw/X.fd', map['bootrom']
      assert_equal '1', map['cpus']                      # generator overrides flavor
      assert_equal '/bhyve/pod34/pod34-root.raw', map['pci.0.3.0.path']
    end
  end

  def test_render_equals_serialized_resolve
    e = entry(disks: [])
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, e.config), "zeta=1\nalpha=2\n")
      d = defaults(dir)
      r = VMCtl::ConfigRenderer.new(d)
      vm = VMCtl::VM.new(e, d)
      assert_equal r.serialize(r.resolve(vm)), r.render(vm)
    end
  end
```

Add to `test/test_vm.rb` (inside `class TestVM`):

```ruby
  def test_resolved_config_is_a_map
    Dir.mktmpdir do |dir|
      cfgdir = File.join(dir, 'configs'); FileUtils.mkdir_p(cfgdir)
      File.write(File.join(cfgdir, 'pod.conf'), "bootrom=/fw/Y.fd\ncpus=9\n")
      d = VMCtl::Defaults.new(
        config_dir: cfgdir, vm_root: '/bhyve', zpool: 'tank/bhyve',
        template: 'pod.conf', link_base: 10, run_dir: File.join(dir, 'run'),
        log_dir: '/l', cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0'
      )
      vm = VMCtl::VM.new(entry, d)
      assert_equal '/fw/Y.fd', vm.resolved_config['bootrom']
      assert_equal '1', vm.resolved_config['cpus']
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/resolve|serialize/" && ruby -Ilib -Itest test/test_vm.rb -n "/resolved_config/"`
Expected: FAIL (`NoMethodError: undefined method 'resolve'` / `resolved_config`).

- [ ] **Step 3: Implement the renderer split**

In `lib/vmctl/config_renderer.rb`, replace the `render` method (lines 18-27) with:

```ruby
    # vm: a VMCtl::VM. Returns the resolved config as a String.
    def render(vm)
      serialize(resolve(vm))
    end

    # Returns the fully merged/generated key map (before serialization):
    # flavor %()-substituted -> options: -> generators (generators win).
    def resolve(vm)
      # Read as binary: flavor comments may hold non-ASCII bytes and the host
      # may run under LANG=C; the scan/substitution must not raise on them.
      text = File.binread(vm.template_path)
      map = parse_pairs(substitute(text, vm.entry))
      stringify(vm.entry.options).each { |k, v| map[k] = v }
      generators.each { |gen| gen.call(vm).each { |k, v| map[k] = v } }
      map
    end

    # Serialize a resolved key map to bhyve_config text (sorted, k=v per line).
    def serialize(map)
      map.sort.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
    end
```

- [ ] **Step 4: Reuse the resolved map in `VM`**

In `lib/vmctl/vm.rb`, replace the `render_config` method (lines 24-26) with:

```ruby
    def resolved_config
      @resolved_config ||= ConfigRenderer.new(@defaults).resolve(self)
    end

    def render_config
      ConfigRenderer.new(@defaults).serialize(resolved_config)
    end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/resolve|serialize/" && ruby -Ilib -Itest test/test_vm.rb -n "/resolved_config/"`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the full suite (render output must be byte-identical)**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green — existing renderer/VM/command tests still pass, proving `serialize(resolve(...))` reproduces the old `render` output exactly.

- [ ] **Step 7: Commit**

```bash
git add lib/vmctl/config_renderer.rb lib/vmctl/vm.rb test/test_config_renderer.rb test/test_vm.rb
git commit -m "refactor(renderer): split render into resolve+serialize; VM#resolved_config"
```

---

### Task 2: bootrom presence check at start

**Files:**
- Modify: `lib/vmctl/commands/start.rb`
- Test: `test/test_commands.rb` (`class TestStartCommand`)

**Interfaces:**
- Consumes: `VM#resolved_config` (Task 1).
- Produces: `start` raises `CommandError` when the resolved `bootrom` file is absent.

- [ ] **Step 1: Write the failing tests**

Add to `class TestStartCommand` in `test/test_commands.rb`:

```ruby
  # A config whose VM's template declares a bootrom path.
  def bootrom_config(rom)
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'uefi.conf'),
               "bootrom=#{rom}\nlpc.com1.path=/dev/nmdm%(link)A\n")
    inv = <<~YAML
      defaults:
        config_dir: #{dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
        log_dir: #{run_dir}
      vms:
        pod34:
          config: uefi.conf
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    f = Tempfile.new(['inv', '.yml']); f.write(inv); f.flush
    VMCtl::Config.load(f.path)
  end

  def test_start_refuses_when_bootrom_missing
    rom = '/fw/BHYVE_UEFI.fd'
    exec = FakeExecutor.new(probes: {
      'ngctl info labs_vlan50:' => true,
      '/dev/vmm/pod34' => false,
      "test -e #{rom}" => false          # bootrom file absent
    })
    cmd = VMCtl::Commands::Start.new(config: bootrom_config(rom), executor: exec,
                                     supervisor_factory: ->(_vm, **) { flunk 'must not start' })
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/bootrom not found/, err.message)
    assert_match(%r{/fw/BHYVE_UEFI\.fd}, err.message)
  end

  def test_start_allows_when_bootrom_present
    rom = '/fw/BHYVE_UEFI.fd'
    # bootrom probe unspecified -> FakeExecutor returns true -> check passes.
    exec = FakeExecutor.new(probes: {
      'ngctl info labs_vlan50:' => true,
      '/dev/vmm/pod34' => false
    })
    started = []
    factory = ->(vm, **) { started << vm.name; TestStartCommand::FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: bootrom_config(rom), executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    assert_equal ['pod34'], started
  end
```

Note: the existing start tests use a template with no `bootrom` line, so the new check is skipped for them (no regression).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_commands.rb -n "/bootrom/"`
Expected: FAIL — `test_start_refuses_when_bootrom_missing` does not raise (check not implemented yet), so `assert_raises` fails.

- [ ] **Step 3: Implement the check**

In `lib/vmctl/commands/start.rb`, add a bootrom check inside `start_one`, immediately after the NIC-bridge loop and before `vm.write_config`:

```ruby
        vm.nic_bridges.each { |b| @netgraph.ensure_bridge!(b) }
        ensure_bootrom!(vm)
        vm.write_config
```

Add the private helper (below `start_one`):

```ruby
      def ensure_bootrom!(vm)
        rom = vm.resolved_config['bootrom']
        return if rom.nil?
        return if executor.success?('test', '-e', rom)
        raise CommandError,
              "bootrom not found: #{rom} (install the uefi-edk2-bhyve package?)"
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_commands.rb -n "/bootrom/"`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/commands/start.rb test/test_commands.rb
git commit -m "feat(start): fail fast when the bootrom firmware file is missing"
```

---

### Task 3: EFI vars schema — `efi_vars` field + `uefi_vars_template` default

**Files:**
- Modify: `lib/vmctl/config.rb`
- Test: `test/test_config.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `VMEntry#efi_vars` — boolean (`false` when absent).
  - `Defaults#uefi_vars_template` — String (default `/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd`).
  - `vm_to_h` emits `'efi_vars' => true` only when truthy.

- [ ] **Step 1: Write the failing tests**

Add to `class TestConfig` in `test/test_config.rb`:

```ruby
  def test_uefi_vars_template_default
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd',
                 cfg.defaults.uefi_vars_template
    f.close
  end

  def test_uefi_vars_template_override
    f = write_inventory("defaults: { uefi_vars_template: /custom/VARS.fd }\nvms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/custom/VARS.fd', cfg.defaults.uefi_vars_template
    f.close
  end

  def test_efi_vars_parsed_and_defaults_false
    f = write_inventory(<<~YAML)
      vms:
        e1: { network: n, link: 10, efi_vars: true }
        e2: { network: n, link: 11 }
    YAML
    cfg = VMCtl::Config.load(f.path)
    assert_equal true, cfg.vms.fetch('e1').efi_vars
    assert_equal false, cfg.vms.fetch('e2').efi_vars
    f.close
  end

  def test_efi_vars_round_trips_only_when_true
    f = write_inventory(<<~YAML)
      vms:
        e1: { network: n, link: 10, efi_vars: true, disks: [] }
        e2: { network: n, link: 11, disks: [] }
    YAML
    cfg = VMCtl::Config.load(f.path)
    h = cfg.to_h
    assert_equal true, h['vms']['e1']['efi_vars']
    refute h['vms']['e2'].key?('efi_vars'), 'efi_vars omitted when false'
    f.close
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/efi_vars|uefi_vars/"`
Expected: FAIL (`NoMethodError: undefined method 'uefi_vars_template'` / efi_vars assertions).

- [ ] **Step 3: Implement the schema changes**

In `lib/vmctl/config.rb`:

Append `:efi_vars` to the `VMEntry` struct member list (after `:graphics`):

```ruby
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options, :mtu, :networks, :cpus, :memory, :graphics, :efi_vars,
    keyword_init: true
  )
```

Append `:uefi_vars_template` to the `Defaults` struct member list (after `:vnc_bind`):

```ruby
  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from, :cpus, :memory, :vnc_base, :vnc_bind,
    :uefi_vars_template,
    keyword_init: true
  )
```

Add the default to `DEFAULTS` (after the `vnc_bind` entry):

```ruby
      'vnc_bind'   => '0.0.0.0',
      'uefi_vars_template' => '/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd'
```

In `parse_defaults`, add to the `Defaults.new(...)` call (after `vnc_bind:`):

```ruby
        vnc_bind:   merged['vnc_bind'],
        uefi_vars_template: merged['uefi_vars_template']
```

In `parse_vm`, add to the `VMEntry.new(...)` call (after `graphics:`):

```ruby
        graphics:   body.fetch('graphics', false),
        efi_vars:   body.fetch('efi_vars', false)
```

In `vm_to_h`, emit `efi_vars` only when truthy (add after the `graphics` line):

```ruby
      h['graphics'] = true if vm.graphics
      h['efi_vars'] = true if vm.efi_vars
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/efi_vars|uefi_vars/"`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "feat(config): efi_vars VM field + uefi_vars_template default"
```

---

### Task 4: `VM#uefi_vars_path` + `firmware_keys` generator

**Files:**
- Modify: `lib/vmctl/vm.rb`
- Modify: `lib/vmctl/config_renderer.rb`
- Test: `test/test_vm.rb`, `test/test_config_renderer.rb`

**Interfaces:**
- Consumes: `entry.efi_vars` (Task 3).
- Produces:
  - `VM#uefi_vars_path → String` = `<vm_root>/<name>/<name>-uefi-vars.fd`.
  - `firmware_keys(vm)` generator emits `{'bootvars' => vm.uefi_vars_path}` when `efi_vars`, else `{}`.

**⚠️ Verify before Step 3:** confirm the exact bhyve_config key for the UEFI vars file by checking `man bhyve_config` on the host (the expected key is `bootvars`). If the man page differs, use that key name and update the test's expected key accordingly. Record what you found in your report.

- [ ] **Step 1: Update test helpers and write failing tests**

In `test/test_config_renderer.rb`, update the `entry` helper signature to accept `efi_vars:` and pass it through (add `efi_vars: false` to the params and `efi_vars: efi_vars` to the `VMEntry.new`):

```ruby
  def entry(disks:, mac: nil, iso: nil, cloud_init: nil, options: {}, config: 'base.conf',
            network: 'labs_vlan50', mtu: nil, networks: [], cpus: nil, memory: nil,
            graphics: false, efi_vars: false)
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: network, link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: cloud_init, iso: iso,
      options: options, mtu: mtu, networks: networks, cpus: cpus, memory: memory,
      graphics: graphics, efi_vars: efi_vars
    )
  end
```

Add renderer tests:

```ruby
  def test_no_bootvars_when_efi_vars_disabled
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/^bootvars=/, out)
  end

  def test_bootvars_generated_when_efi_vars_enabled
    out = render("cpus=2\n", entry(disks: [], efi_vars: true))
    assert_match(%r{^bootvars=/bhyve/pod34/pod34-uefi-vars\.fd$}, out)
  end
```

In `test/test_vm.rb`, add:

```ruby
  def test_uefi_vars_path
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal '/bhyve/pod34/pod34-uefi-vars.fd', vm.uefi_vars_path
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/bootvars/" && ruby -Ilib -Itest test/test_vm.rb -n "/uefi_vars_path/"`
Expected: FAIL (`NoMethodError: undefined method 'uefi_vars_path'` / no `bootvars` emitted).

- [ ] **Step 3: Implement `uefi_vars_path` and the generator**

In `lib/vmctl/vm.rb`, add after `disk_paths` (around line 68):

```ruby
    def uefi_vars_path
      File.join(dir, "#{name}-uefi-vars.fd")
    end
```

In `lib/vmctl/config_renderer.rb`, append `firmware_keys` to the `generators` list:

```ruby
    def generators
      [method(:disk_keys), method(:net_keys), method(:iso_cd_keys),
       method(:seed_cd_keys), method(:hardware_keys), method(:graphics_keys),
       method(:firmware_keys)]
    end
```

Add the generator method (place it after `graphics_keys`):

```ruby
    # Persistent UEFI variables store, generated when efi_vars: true. The file is
    # provisioned lazily at start (copied from the pristine host template).
    def firmware_keys(vm)
      return {} unless vm.entry.efi_vars
      { 'bootvars' => vm.uefi_vars_path }
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/bootvars/" && ruby -Ilib -Itest test/test_vm.rb -n "/uefi_vars_path/"`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/vm.rb lib/vmctl/config_renderer.rb test/test_vm.rb test/test_config_renderer.rb
git commit -m "feat(renderer): firmware_keys generator emits bootvars for efi_vars VMs"
```

---

### Task 5: lazy vars-file provisioning at start

**Files:**
- Modify: `lib/vmctl/commands/start.rb`
- Test: `test/test_commands.rb` (`class TestStartCommand`)

**Interfaces:**
- Consumes: `entry.efi_vars` (Task 3), `VM#uefi_vars_path` (Task 4), `Defaults#uefi_vars_template` (Task 3).
- Produces: at start, an `efi_vars` VM's vars file is copied from the pristine template when missing; a missing template is a hard error.

- [ ] **Step 1: Write the failing tests**

Add to `class TestStartCommand` in `test/test_commands.rb`. This helper builds an `efi_vars` VM on a bootrom-less template (so the bootrom check is skipped and these tests isolate the vars behavior):

```ruby
  def efi_config
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'pod.conf'), "lpc.com1.path=/dev/nmdm%(link)A\n")
    inv = <<~YAML
      defaults:
        config_dir: #{dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
        log_dir: #{run_dir}
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          efi_vars: true
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    f = Tempfile.new(['inv', '.yml']); f.write(inv); f.flush
    VMCtl::Config.load(f.path)
  end

  TEMPLATE = '/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd'
  VARS = '/bhyve/pod34/pod34-uefi-vars.fd'

  def test_start_copies_pristine_vars_when_missing
    exec = FakeExecutor.new(probes: {
      'ngctl info labs_vlan50:' => true,
      '/dev/vmm/pod34' => false,
      "test -e #{VARS}" => false          # per-VM vars file absent -> must copy
      # TEMPLATE probe unspecified -> true (template present)
    })
    factory = ->(_vm, **) { TestStartCommand::FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: efi_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    assert_includes exec.runs, ['cp', TEMPLATE, VARS]
  end

  def test_start_skips_copy_when_vars_present
    exec = FakeExecutor.new(probes: {
      'ngctl info labs_vlan50:' => true,
      '/dev/vmm/pod34' => false
      # VARS probe unspecified -> true (file present) -> no copy
    })
    factory = ->(_vm, **) { TestStartCommand::FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: efi_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    refute(exec.runs.any? { |a| a.first == 'cp' }, 'must not copy when vars exist')
  end

  def test_start_refuses_when_vars_template_missing
    exec = FakeExecutor.new(probes: {
      'ngctl info labs_vlan50:' => true,
      '/dev/vmm/pod34' => false,
      "test -e #{VARS}" => false,
      "test -e #{TEMPLATE}" => false      # pristine template absent
    })
    cmd = VMCtl::Commands::Start.new(config: efi_config, executor: exec,
                                     supervisor_factory: ->(_vm, **) { flunk 'must not start' })
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/UEFI vars template not found/, err.message)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_commands.rb -n "/vars/"`
Expected: FAIL (`cp` not recorded / no error raised — provisioning not implemented).

- [ ] **Step 3: Implement lazy provisioning**

In `lib/vmctl/commands/start.rb`, call the provisioner in `start_one`, right after `ensure_bootrom!(vm)` and before `vm.write_config`:

```ruby
        ensure_bootrom!(vm)
        ensure_efi_vars!(vm)
        vm.write_config
```

Add the private helper (below `ensure_bootrom!`):

```ruby
      def ensure_efi_vars!(vm)
        return unless vm.entry.efi_vars
        template = config.defaults.uefi_vars_template
        unless executor.success?('test', '-e', template)
          raise CommandError,
                "UEFI vars template not found: #{template} (install the uefi-edk2-bhyve package?)"
        end
        return if executor.success?('test', '-e', vm.uefi_vars_path)
        executor.run('cp', template, vm.uefi_vars_path)
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_commands.rb -n "/vars/"`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/commands/start.rb test/test_commands.rb
git commit -m "feat(start): lazily provision per-VM UEFI vars file from pristine template"
```

---

### Task 6: CLI — `create --efi-vars`, `set --efi-vars`/`--no-efi-vars`/`--reset-efi-vars`

**Files:**
- Modify: `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/set.rb`, `lib/vmctl/cli.rb`
- Test: `test/test_create_command.rb`, `test/test_set_command.rb`

**Interfaces:**
- Consumes: `VMEntry#efi_vars` (Task 3), `VM#uefi_vars_path` (Task 4).
- Produces: `create --efi-vars` sets the field; `set --efi-vars`/`--no-efi-vars` toggle it; `set --reset-efi-vars` runs `rm -f <uefi_vars_path>`.

- [ ] **Step 1: Write the failing tests**

Add to `class TestCreateCommand` in `test/test_create_command.rb`:

```ruby
  def test_create_with_efi_vars
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--efi-vars']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod35').efi_vars
  end

  def test_create_without_efi_vars_defaults_false
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod35').efi_vars
  end
```

Add to `class TestSetCommand` in `test/test_set_command.rb`:

```ruby
  def test_set_efi_vars
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--efi-vars']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').efi_vars
  end

  def efi_inventory
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          efi_vars: true
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
  end

  def test_set_no_efi_vars
    efi_inventory
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-efi-vars']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').efi_vars
  end

  def test_set_reset_efi_vars_removes_file
    efi_inventory
    exec = stopped
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--reset-efi-vars']) }
    assert_includes exec.runs, ['rm', '-f', '/bhyve/pod34/pod34-uefi-vars.fd']
  end

  def test_set_reset_efi_vars_errors_when_disabled
    # default inventory (setup) has no efi_vars on pod34
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--reset-efi-vars']) }
    assert_match(/does not have efi_vars/, err.message)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_create_command.rb -n "/efi_vars/" && ruby -Ilib -Itest test/test_set_command.rb -n "/efi_vars/"`
Expected: FAIL (`--efi-vars` unknown option / values not set / no `rm` recorded).

- [ ] **Step 3: Implement `create --efi-vars`**

In `lib/vmctl/commands/create.rb`, add the flag to `parse` (after the `--graphics` line):

```ruby
          p.on('--graphics')    { o[:graphics] = true }
          p.on('--efi-vars')    { o[:efi_vars] = true }
          p.on('--start')       { o[:start] = true }
```

Add `efi_vars:` to the `VMEntry.new(...)` in `build_entry` (after `graphics:`):

```ruby
          graphics: !!opts[:graphics],
          efi_vars: !!opts[:efi_vars]
```

- [ ] **Step 4: Implement `set` flags**

In `lib/vmctl/commands/set.rb`, add the flags to the `OptionParser` block (after the `--no-graphics` line):

```ruby
          p.on('--graphics')     { opts[:graphics] = true }
          p.on('--no-graphics')  { opts[:graphics] = false }
          p.on('--efi-vars')     { opts[:efi_vars] = true }
          p.on('--no-efi-vars')  { opts[:efi_vars] = false }
          p.on('--reset-efi-vars') { opts[:reset_efi_vars] = true }
```

Add the apply clauses in `apply!` (after the `graphics` clause, before the trailing `apply_iso!`/`apply_cloud_init!` lines):

```ruby
        if opts.key?(:efi_vars)
          e.efi_vars = opts[:efi_vars]
          changed << "efi_vars=#{e.efi_vars}"
        end
        if opts[:reset_efi_vars]
          reset_efi_vars!(vm, changed)
        end
```

Add the private helper (below `apply!`, near `apply_iso!`):

```ruby
      def reset_efi_vars!(vm, changed)
        raise CommandError, "#{vm.name} does not have efi_vars enabled" unless vm.entry.efi_vars
        executor.run('rm', '-f', vm.uefi_vars_path)
        changed << 'efi_vars=reset'
      end
```

- [ ] **Step 5: Update the CLI usage line**

In `lib/vmctl/cli.rb`, update the `set` usage line to list the new flags (add `/--efi-vars/--reset-efi-vars` before `/--config`):

```ruby
        set <name> [opts]       Change VM fields (--autostart/--network[ none]/--mac/--mtu/--cpus/--memory/--graphics/--efi-vars/--reset-efi-vars/--config/--iso/--cloud-init/--var/--no-cloud-init).
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_create_command.rb -n "/efi_vars/" && ruby -Ilib -Itest test/test_set_command.rb -n "/efi_vars/"`
Expected: PASS (6 tests).

- [ ] **Step 7: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add lib/vmctl/commands/create.rb lib/vmctl/commands/set.rb lib/vmctl/cli.rb \
        test/test_create_command.rb test/test_set_command.rb
git commit -m "feat(cli): create/set --efi-vars, set --no-efi-vars/--reset-efi-vars"
```

---

### Task 7: Docs — README + example inventory

**Files:**
- Modify: `README.md`, `examples/inventory.yml`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Document the fields in the example inventory**

Read `examples/inventory.yml` first and match its aligned inline-comment style. Under `defaults:` (which currently ends with the `vnc_bind` line added by the graphics feature), add:

```yaml
  uefi_vars_template: /usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd  # pristine UEFI vars store (from uefi-edk2-bhyve), copied per-VM when efi_vars: true
```

And add a commented example line to one existing VM entry:

```yaml
    # efi_vars: true   # give this VM a persistent UEFI variables store (boot order etc. survive reboots)
```

Do not restructure the file or change unrelated lines.

- [ ] **Step 2: Document both parts in the README**

Read `README.md` first (the generated-devices / inventory-fields section — the same bulleted list the graphics feature was added to). Add:

1. A bullet in that list for **persistent UEFI vars**:
   - `efi_vars: true` gives a VM a writable UEFI variables store (`bootvars`), copied from the host's pristine template (`defaults.uefi_vars_template`, default `/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd`) into `<vm_root>/<name>/<name>-uefi-vars.fd` on first start.
   - Boot order and other UEFI settings then persist across restarts.
   - Reset to factory with `vmctl set <name> --reset-efi-vars` (removes the file; recreated pristine on next start).
   - Disable with `set --no-efi-vars`. Default is off.

2. A short note (near the `start` behavior / templates paragraph) that **`start` verifies the `bootrom` firmware file exists** and fails fast with an install hint if it does not.

Match the README's existing heading level and prose style. Do not restructure existing sections.

- [ ] **Step 3: Run the full suite (docs shouldn't affect it; confirm)**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add README.md examples/inventory.yml
git commit -m "docs: document efi_vars persistent UEFI store + bootrom start check"
```

---

## Self-Review

**Spec coverage:**
- Renderer `resolve`/`serialize` split + `VM#resolved_config` (byte-identical render) → Task 1. ✓
- bootrom presence check at start (hard error, executor `test -e`, skip when absent) → Task 2. ✓
- `efi_vars` field on `VMEntry`; `uefi_vars_template` default + `DEFAULTS`; `vm_to_h` emits only when true → Task 3. ✓
- `VM#uefi_vars_path` = `<vm_root>/<name>/<name>-uefi-vars.fd` → Task 4. ✓
- `firmware_keys` generator emits `bootvars` only when `efi_vars`, appended last → Task 4. ✓
- `bootvars` key host-verification (⚠️) → Task 4 pre-Step-3 note. ✓
- Lazy provisioning at start: template-missing → error; copy pristine when file missing; skip when present → Task 5. ✓
- `create --efi-vars`; `set --efi-vars`/`--no-efi-vars`/`--reset-efi-vars`; usage line → Task 6. ✓
- Reset = `rm -f` the file; errors when efi_vars disabled → Task 6. ✓
- `destroy --purge` wipes the file via `zfs destroy` (no code change) → covered by placement in the dataset dir (Task 4), noted in spec; no task needed. ✓
- README + example inventory (both parts) → Task 7. ✓
- No migration; `--dry-run` skips checks (start returns early) → constraints + start's existing early return; no task needed. ✓

**Placeholder scan:** No TBD/TODO. The Task 4 ⚠️ note is an explicit host-verification action (with the expected value `bootvars` and a concrete fallback instruction), not a placeholder. Task 7 says "read the file and match its style" because the README/example structure isn't reproduced here, but the required content is fully enumerated.

**Type consistency:** `efi_vars` is a boolean everywhere (`entry.efi_vars`, `opts[:efi_vars]`, `body.fetch('efi_vars', false)`, `!!opts[:efi_vars]`). `uefi_vars_template` is a String on `Defaults`. `VM#uefi_vars_path` returns a String and is consumed by `firmware_keys` (Task 4), `ensure_efi_vars!` (Task 5), and `reset_efi_vars!` (Task 6) with the same name. `resolve`/`serialize`/`resolved_config` names match across Tasks 1–2. `firmware_keys` appended after `graphics_keys` in the generators list, consistent with the Task-order additions. `ensure_bootrom!` / `ensure_efi_vars!` are both private helpers on `Start`, called in sequence in `start_one`.
