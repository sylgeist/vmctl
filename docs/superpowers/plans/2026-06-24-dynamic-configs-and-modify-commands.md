# Dynamic Configs + VM Modify Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate each VM's bhyve config from a base flavor file + its inventory entry (disks become the single source of truth), then add `add-disk`/`grow-disk`/`remove-disk`/`set` convenience commands on top.

**Architecture:** A new pure `ConfigRenderer` merges three layers — base flavor file (`%()` substituted) → per-VM `options:` → generated managed keys (disks today) — into an ephemeral, always-latest `run_dir/<name>.conf` that `bhyve -k` boots from. The four modify commands are thin handlers that mutate the inventory entry (+ backing files) and persist via the existing `Config#save`.

**Tech Stack:** Ruby (stdlib only — `optparse`, `yaml`, `fileutils`, `tempfile`), minitest, `FakeExecutor` test double.

## Global Constraints

- Ruby 4.0 (CI runs `ruby -Ilib -Itest test/run_all.rb` on Ruby 4.0).
- No new gem dependencies — stdlib only.
- Every file starts with `# frozen_string_literal: true` then `# lib/vmctl/<path>` (match existing headers).
- Tests are minitest, named `test/test_*.rb`, and use `FakeExecutor` at every shell-out boundary. Run all: `ruby -Ilib -Itest test/run_all.rb`. Single file: `ruby -Ilib -Itest test/test_x.rb`. Single test: `ruby -Ilib -Itest test/test_x.rb -n test_name`.
- Errors surfaced to the user are `VMCtl::Commands::CommandError` (CLI maps to exit 1).
- Disks live on `pci.0.3.N` (functions 0–7, **max 8 disks**). Disk index 0 is root by convention.
- Variant A: only disks are generated; the installer iso CD and cloud-init seed CD stay template-owned via `%()` substitution. `validate_iso_pairing!` and `template_wants_iso?` are kept.
- Git commits end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Work happens on branch `feat/dynamic-configs-modify`.

---

## Task 1: `options:` field on `VMEntry`

**Files:**
- Modify: `lib/vmctl/config.rb` (VMEntry struct, `parse_vm`, `vm_to_h`)
- Test: `test/test_config.rb`

**Interfaces:**
- Produces: `VMEntry#options` → `Hash` (string keys/values as authored; default `{}`). `vm_to_h` emits `'options'` only when non-empty.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config.rb`:

```ruby
  def test_options_default_empty
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    assert_equal({}, cfg.vms.fetch('pod34').options)
    f.close
  end

  def test_options_parsed_and_roundtrip
    inv = <<~YAML
      defaults: { config_dir: /c, vm_root: /v, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: []
          options:
            cpus: 4
            memory.size: 8G
    YAML
    f = write_inventory(inv)
    cfg = VMCtl::Config.load(f.path)
    assert_equal({ 'cpus' => 4, 'memory.size' => '8G' }, cfg.vms.fetch('pod34').options)

    out = Tempfile.new(['out', '.yml'])
    cfg.save(out.path)
    reloaded = VMCtl::Config.load(out.path)
    assert_equal({ 'cpus' => 4, 'memory.size' => '8G' }, reloaded.vms.fetch('pod34').options)
    f.close; out.close
  end

  def test_options_absent_not_emitted
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    out = Tempfile.new(['out', '.yml'])
    cfg.save(out.path)
    refute_match(/options:/, File.read(out.path))
    f.close; out.close
  end

  def test_options_must_be_mapping
    inv = "vms:\n  pod34:\n    network: n\n    link: 10\n    disks: []\n    options: [1,2]\n"
    f = write_inventory(inv)
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb -n test_options_parsed_and_roundtrip`
Expected: FAIL (`NoMethodError: undefined method 'options'` / unknown keyword).

- [ ] **Step 3: Implement**

In `lib/vmctl/config.rb`, add `:options` to the `VMEntry` struct members:

```ruby
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options,
    keyword_init: true
  )
```

In `parse_vm`, add the `options:` member (after `iso:`):

```ruby
        iso:        body['iso'],
        options:    parse_options(body.fetch('options', {}))
```

Add a private parser near `parse_disks`:

```ruby
    def parse_options(h)
      h ||= {}
      raise ConfigError, "'options' must be a mapping" unless h.is_a?(Hash)
      h
    end
```

In `vm_to_h`, emit it only when non-empty (after the `iso` line):

```ruby
      h['options'] = vm.options unless vm.options.nil? || vm.options.empty?
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb`
Expected: PASS (all config tests, including the four new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "$(printf 'feat(config): add per-VM options map to VMEntry\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 2: `ConfigRenderer`

**Files:**
- Create: `lib/vmctl/config_renderer.rb`
- Test: `test/test_config_renderer.rb`

**Interfaces:**
- Consumes: a `VMCtl::VM` exposing `template_path` (path to flavor file), `dir` (VM dir), and `entry` (with `name/network/link/mac/iso/disks/options`).
- Produces: `ConfigRenderer.new(defaults).render(vm)` → `String` (sorted `key=value` lines, trailing newline). Disk index N → `pci.0.3.N.device=nvme` + `pci.0.3.N.path=<dir>/<file>`.

- [ ] **Step 1: Write the failing tests**

Create `test/test_config_renderer.rb`:

```ruby
# frozen_string_literal: true
# test/test_config_renderer.rb
require 'test_helper'
require 'tmpdir'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/config_renderer'

class TestConfigRenderer < Minitest::Test
  def defaults(config_dir)
    VMCtl::Defaults.new(
      config_dir: config_dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'base.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
    )
  end

  def entry(disks:, mac: nil, iso: nil, options: {}, config: 'base.conf')
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: 'labs_vlan50', link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: nil, iso: iso,
      options: options
    )
  end

  def render(flavor_body, e)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, e.config), flavor_body)
      vm = VMCtl::VM.new(e, defaults(dir))
      return VMCtl::ConfigRenderer.new(defaults(dir)).render(vm)
    end
  end

  def test_substitutes_placeholders
    out = render("lpc.com1.path=/dev/nmdm%(link)A\nnet=%(network)\n",
                 entry(disks: []))
    assert_match(%r{^lpc\.com1\.path=/dev/nmdm10A$}, out)
    assert_match(/^net=labs_vlan50$/, out)
  end

  def test_generates_disk_slots
    e = entry(disks: [
      VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil),
      VMCtl::Disk.new(file: 'pod34-data.raw', size: '50G', from: nil)
    ])
    out = render("cpus=2\n", e)
    assert_match(/^pci\.0\.3\.0\.device=nvme$/, out)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(/^pci\.0\.3\.1\.device=nvme$/, out)
    assert_match(%r{^pci\.0\.3\.1\.path=/bhyve/pod34/pod34-data\.raw$}, out)
  end

  def test_no_disks_no_disk_keys
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.3\./, out)
  end

  def test_eight_disks
    disks = (0...8).map { |i| VMCtl::Disk.new(file: "pod34-d#{i}.raw", size: '1G', from: nil) }
    out = render("cpus=2\n", entry(disks: disks))
    assert_match(/^pci\.0\.3\.7\.device=nvme$/, out)
  end

  def test_options_override_base
    out = render("cpus=2\nmemory.size=4G\n",
                 entry(disks: [], options: { 'cpus' => 4 }))
    assert_match(/^cpus=4$/, out)
    refute_match(/^cpus=2$/, out)
  end

  def test_managed_disk_keys_beat_options
    e = entry(disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)],
              options: { 'pci.0.3.0.path' => '/evil' })
    out = render("cpus=2\n", e)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, out)
    refute_match(%r{/evil}, out)
  end

  def test_comments_and_blank_lines_dropped
    out = render("# a comment\n\ncpus=2\n", entry(disks: []))
    refute_match(/comment/, out)
    assert_match(/^cpus=2$/, out)
  end

  def test_output_is_sorted
    out = render("zeta=1\nalpha=2\n", entry(disks: []))
    assert_equal %w[alpha=2 zeta=1], out.split("\n")
  end

  def test_iso_substituted_when_set
    out = render("pci.0.5.0.port.0.path=%(iso)\n",
                 entry(disks: [], iso: '/iso/x.iso'))
    assert_match(%r{^pci\.0\.5\.0\.port\.0\.path=/iso/x\.iso$}, out)
  end

  def test_tolerates_non_ascii_bytes_in_comments
    body = +"# notes \xFF \xE2\x80\x94 bytes\n".b
    body << "cpus=2\n"
    out = render(body, entry(disks: []))
    assert_match(/^cpus=2$/, out)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n test_generates_disk_slots`
Expected: FAIL (`cannot load such file -- vmctl/config_renderer`).

- [ ] **Step 3: Implement**

Create `lib/vmctl/config_renderer.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/config_renderer.rb
module VMCtl
  # Renders a VM's fully-resolved bhyve config from its base flavor file plus the
  # inventory entry. Pure: text/data in, config text out (no file writing).
  #
  # Layering (low -> high precedence):
  #   1. base flavor file, with %() substituted to concrete values
  #   2. per-VM options: map
  #   3. managed generated keys (disks today) -- always win
  class ConfigRenderer
    def initialize(defaults)
      @defaults = defaults
    end

    # vm: a VMCtl::VM. Returns the resolved config as a String.
    def render(vm)
      # Read as binary: flavor comments may hold non-ASCII bytes and the host
      # may run under LANG=C; the scan/substitution must not raise on them.
      text = File.binread(vm.template_path)
      map = parse_pairs(substitute(text, vm.entry))
      stringify(vm.entry.options).each { |k, v| map[k] = v }
      generators.each { |gen| gen.call(vm).each { |k, v| map[k] = v } }
      map.sort.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
    end

    private

    # Ordered managed-key generators, merged last so they always win. To promote
    # the net block / iso CD / cloud-init seed to generated wiring later, append a
    # generator here -- no other change is required.
    def generators
      [method(:disk_keys)]
    end

    def disk_keys(vm)
      keys = {}
      vm.entry.disks.each_with_index do |disk, n|
        keys["pci.0.3.#{n}.device"] = 'nvme'
        keys["pci.0.3.#{n}.path"]   = File.join(vm.dir, disk.file)
      end
      keys
    end

    def substitute(text, entry)
      vars = {
        'name'    => entry.name.to_s,
        'network' => entry.network.to_s,
        'link'    => entry.link.to_s,
        'mac'     => entry.mac.to_s,
        'iso'     => entry.iso.to_s
      }
      text.gsub(/%\((\w+)\)/) { vars.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
    end

    def parse_pairs(text)
      map = {}
      text.each_line do |line|
        s = line.strip
        next if s.empty? || s.start_with?('#')
        key, val = s.split('=', 2)
        next if val.nil?
        map[key.strip] = val.strip
      end
      map
    end

    def stringify(opts)
      (opts || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb`
Expected: PASS (all 11 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config_renderer.rb test/test_config_renderer.rb
git commit -m "$(printf 'feat: ConfigRenderer resolves base flavor + inventory to bhyve config\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 3: Wire `VM` to the renderer + ephemeral config file

**Files:**
- Modify: `lib/vmctl/vm.rb`
- Test: `test/test_vm.rb`

**Interfaces:**
- Consumes: `ConfigRenderer.new(defaults).render(self)`.
- Produces: `VM#config_path` → `<run_dir>/<name>.conf`; `VM#render_config` → String; `VM#write_config` → writes the file, returns the path; `VM#bhyve_argv` → `['bhyve', '-k', config_path, name]`. `dump_command` removed; `template_wants_iso?` kept.

- [ ] **Step 1: Replace the affected tests**

In `test/test_vm.rb`: **delete** `test_bhyve_argv_without_mac`, `test_bhyve_argv_includes_mac_when_set`, `test_bhyve_command_is_joined_string`, `test_dump_command_inserts_config_dump_before_name`, `test_dump_command_with_mac_keeps_order`, `test_bhyve_argv_includes_iso_when_set`, `test_bhyve_argv_omits_iso_when_nil`, `test_dump_command_includes_iso_when_set`. Keep all `test_template_wants_iso_*` and `test_paths`.

Add `require 'tmpdir'` (already present) and these tests:

```ruby
  def test_config_path_in_run_dir
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal '/var/run/vmctl/pod34.conf', vm.config_path
  end

  def test_bhyve_argv_references_ephemeral_config
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(['bhyve', '-k', '/var/run/vmctl/pod34.conf', 'pod34'], vm.bhyve_argv)
  end

  def test_bhyve_command_is_joined_string
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal 'bhyve -k /var/run/vmctl/pod34.conf pod34', vm.bhyve_command
  end

  def test_render_and_write_config
    Dir.mktmpdir do |dir|
      cfgdir = File.join(dir, 'configs'); FileUtils.mkdir_p(cfgdir)
      File.write(File.join(cfgdir, 'pod.conf'),
                 "cpus=2\nlpc.com1.path=/dev/nmdm%(link)A\n")
      run = File.join(dir, 'run')
      d = VMCtl::Defaults.new(
        config_dir: cfgdir, vm_root: '/bhyve', zpool: 'tank/bhyve',
        template: 'pod.conf', link_base: 10, run_dir: run, log_dir: '/l'
      )
      vm = VMCtl::VM.new(entry, d)
      text = vm.render_config
      assert_match(/^cpus=2$/, text)
      assert_match(%r{^lpc\.com1\.path=/dev/nmdm10A$}, text)
      assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, text)
      path = vm.write_config
      assert_equal File.join(run, 'pod34.conf'), path
      assert_equal text, File.binread(path)
    end
  end
```

The `entry` helper in this file builds a `VMEntry` without `options:` (defaults to `nil`); `render` handles `nil` via `stringify`. Leave the helper as-is.

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_vm.rb -n test_bhyve_argv_references_ephemeral_config`
Expected: FAIL (old `bhyve_argv` still emits `-o network=...`).

- [ ] **Step 3: Implement**

In `lib/vmctl/vm.rb`, add requires at the top (after the header comment):

```ruby
require 'fileutils'
require_relative 'config_renderer'
```

Replace `bhyve_argv` and `dump_command` with:

```ruby
    def config_path
      File.join(@defaults.run_dir, "#{name}.conf")
    end

    def render_config
      ConfigRenderer.new(@defaults).render(self)
    end

    def write_config
      FileUtils.mkdir_p(@defaults.run_dir)
      File.binwrite(config_path, render_config)
      config_path
    end

    def bhyve_argv
      ['bhyve', '-k', config_path, name]
    end
```

Keep `bhyve_command` (it joins `bhyve_argv`). Delete the old `dump_command` method entirely. Leave `template_wants_iso?`, `disk_paths`, and everything else unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_vm.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/vm.rb test/test_vm.rb
git commit -m "$(printf 'feat(vm): render ephemeral run_dir config; bhyve -k that file\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 4: `start` writes the config before launch

**Files:**
- Modify: `lib/vmctl/commands/start.rb`
- Test: `test/test_commands.rb`

**Interfaces:**
- Consumes: `VM#write_config`, `VM#bhyve_command`.
- Produces: non-dry-run `start_one` calls `vm.write_config` after the bridge check and before the supervisor starts. Dry-run prints `[dry-run] <vm.bhyve_command>` (now `bhyve -k <run_dir>/<name>.conf <name>`).

- [ ] **Step 1: Refactor the shared test fixture + update assertions**

In `test/test_commands.rb`, replace the `CmdTestSupport` module's `INVENTORY` constant and `load_config` with a version that writes a real flavor file and a temp `run_dir` (the start path now reads the flavor and writes a config):

```ruby
module CmdTestSupport
  def config_dir
    @config_dir ||= begin
      d = Dir.mktmpdir
      File.write(File.join(d, 'pod.conf'),
                 "cpus=2\nlpc.com1.path=/dev/nmdm%(link)A\n")
      d
    end
  end

  def run_dir
    @run_dir ||= Dir.mktmpdir
  end

  def inventory
    <<~YAML
      defaults:
        config_dir: #{config_dir}
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
          autostart: true
          disks: [{ file: pod34-root.raw, size: 20G }]
        pod35:
          config: pod.conf
          network: labs_vlan50
          link: 11
          autostart: false
          disks: [{ file: pod35-root.raw, size: 20G }]
    YAML
  end

  def load_config
    f = Tempfile.new(['inv', '.yml'])
    f.write(inventory)
    f.flush
    VMCtl::Config.load(f.path)
  end

  def capture_stdout
    out = StringIO.new
    $stdout = out
    yield
    out.string
  ensure
    $stdout = STDOUT
  end
end
```

Update the two dry-run assertions (in `TestStartCommand#test_start_dry_run_prints_command_and_does_not_start` and `TestRestartCommand#test_restart_dry_run_stops_then_prints_start`): replace `assert_match(%r{bhyve -k /bhyve/configs/pod\.conf}, out)` with:

```ruby
    assert_match(%r{bhyve -k .*/pod34\.conf pod34}, out)
```

Add a test asserting the config file is written on a real start:

```ruby
  def test_start_writes_ephemeral_config
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => true, '/dev/vmm/pod34' => false }
    )
    factory = ->(_vm, **) { FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    written = File.read(File.join(run_dir, 'pod34.conf'))
    assert_match(/^cpus=2$/, written)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, written)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_commands.rb -n test_start_writes_ephemeral_config`
Expected: FAIL (no `pod34.conf` written yet).

- [ ] **Step 3: Implement**

In `lib/vmctl/commands/start.rb`, add `vm.write_config` to `start_one` (after the bridge check, before the factory call):

```ruby
      def start_one(vm)
        if executor.dry_run?
          puts "[dry-run] #{vm.bhyve_command}"
          return
        end
        raise CommandError, "#{vm.name} already running" if vm.running?(executor)
        validate_iso_pairing!(vm)
        @netgraph.ensure_bridge!(vm.entry.network)
        vm.write_config
        sup = @factory.call(vm)
        pid = sup.start
        puts "started #{vm.name} (supervisor pid #{pid})"
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_commands.rb`
Expected: PASS (all command tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/start.rb test/test_commands.rb
git commit -m "$(printf 'feat(start): write the ephemeral config before launching bhyve\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 5: `dump` renders directly

**Files:**
- Modify: `lib/vmctl/commands/dump.rb`
- Test: `test/test_dump_command.rb` (rewrite)

**Interfaces:**
- Consumes: `VM#render_config`.
- Produces: `dump <name>` prints the rendered config; unknown VM / missing name / missing flavor file → `CommandError`. No executor use.

- [ ] **Step 1: Rewrite the test file**

Replace `test/test_dump_command.rb` entirely:

```ruby
# frozen_string_literal: true
# test/test_dump_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'vmctl/config'
require 'vmctl/commands/dump'
require 'tempfile'

class TestDumpCommand < Minitest::Test
  def load_config(template: "cpus=2\nmemory.size=4G\nlpc.com1.path=/dev/nmdm%(link)A\n",
                  config: 'pod.conf')
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'pod.conf'), template)
    inv = <<~YAML
      defaults:
        config_dir: #{dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: /var/run/vmctl
      vms:
        pod34:
          config: #{config}
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    f = Tempfile.new(['inv', '.yml'])
    f.write(inv)
    f.flush
    VMCtl::Config.load(f.path)
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_dump_prints_rendered_config
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/^memory\.size=4G$/, out)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(%r{^lpc\.com1\.path=/dev/nmdm10A$}, out)
  end

  def test_dump_requires_a_name
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call([]) }
  end

  def test_dump_unknown_vm
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost']) }
  end

  def test_dump_missing_flavor_file_raises
    cmd = VMCtl::Commands::Dump.new(config: load_config(config: 'nope.conf'),
                                    executor: FakeExecutor.new)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/could not render config/, err.message)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_dump_command.rb -n test_dump_prints_rendered_config`
Expected: FAIL (old dump shells out to `config.dump=1`).

- [ ] **Step 3: Implement**

Replace `lib/vmctl/commands/dump.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/dump.rb
require_relative 'base'

module VMCtl
  module Commands
    # Print a VM's fully-resolved bhyve config (base flavor + inventory, with
    # disks generated). Read-only; renders the same text `start` writes.
    class Dump < Base
      def call(args)
        name = args.first
        raise CommandError, 'dump requires a VM name' unless name
        vm = vm_for(name)
        begin
          print vm.render_config
        rescue Errno::ENOENT => e
          raise CommandError, "could not render config for #{vm.name}: #{e.message}"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_dump_command.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/dump.rb test/test_dump_command.rb
git commit -m "$(printf 'refactor(dump): render config directly instead of bhyve config.dump\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 6: Migrate example flavors + README

**Files:**
- Modify: `examples/pod.conf`, `examples/pod-installer.conf`, `examples/pod-cloudinit.conf`
- Modify: `README.md`
- Test: none (docs/examples); run the full suite to confirm nothing regressed.

**Interfaces:** none (no code).

- [ ] **Step 1: Remove disk declarations from the example flavors**

In `examples/pod.conf`, delete the four disk lines:

```
pci.0.3.0.device=nvme
pci.0.3.0.path=/bhyve/%(name)/%(name)-root.raw
pci.0.3.1.device=nvme
pci.0.3.1.path=/bhyve/%(name)/%(name)-zfs.raw
```

and replace the header comment block that says "This template declares TWO nvme disks…" with:

```
# vmctl now GENERATES disk devices from each VM's inventory `disks:` list
# (pci.0.3.N). Do NOT declare pci.0.3.* disks here. Net, console, and any CD
# devices stay in the flavor and use %() placeholders, which vmctl resolves when
# it renders the ephemeral /var/run/vmctl/<name>.conf at start.
```

In `examples/pod-installer.conf` and `examples/pod-cloudinit.conf`, delete their `pci.0.3.*` disk lines too (keep the AHCI CD device blocks). Add a one-line note to each header that disks come from the inventory.

- [ ] **Step 2: Update the README**

In `README.md`, find the section describing templates/config and add (adapt wording to the surrounding prose):

```
Disk devices are generated by vmctl from each VM's inventory `disks:` list and
attached at `pci.0.3.N` (max 8). Base/flavor `.conf` files must NOT declare
`pci.0.3.*` disks. At `start`, vmctl renders the fully-resolved config to
`<run_dir>/<name>.conf` (ephemeral, regenerated every start — do not hand-edit)
and launches `bhyve -k <run_dir>/<name>.conf <name>`. Per-VM `options:` in the
inventory merge over the flavor; generated disk keys always win.
```

- [ ] **Step 3: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS (no code changed; this confirms examples/docs edits didn't touch anything load-bearing).

- [ ] **Step 4: Commit**

```bash
git add examples/pod.conf examples/pod-installer.conf examples/pod-cloudinit.conf README.md
git commit -m "$(printf 'docs: flavors no longer declare disks; vmctl generates pci.0.3.N\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 7: Extract `Disk.parse` grammar

**Files:**
- Modify: `lib/vmctl/config.rb` (Disk struct), `lib/vmctl/commands/create.rb`
- Test: `test/test_config.rb`

**Interfaces:**
- Produces: `Disk.parse(name, spec)` → `Disk` for `"<suffix>:<size>[:from <image>]"`; raises `ArgumentError` on malformed input. `Create#parse_disk` now delegates and re-raises as `CommandError` (message still contains `--disk`).

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config.rb`:

```ruby
  def test_disk_parse_basic
    d = VMCtl::Disk.parse('pod34', 'data:50G')
    assert_equal 'pod34-data.raw', d.file
    assert_equal '50G', d.size
    assert_nil d.from
  end

  def test_disk_parse_with_from
    d = VMCtl::Disk.parse('pod34', 'data:50G:from gold.raw')
    assert_equal 'pod34-data.raw', d.file
    assert_equal '50G', d.size
    assert_equal 'gold.raw', d.from
  end

  def test_disk_parse_rejects_missing_size
    assert_raises(ArgumentError) { VMCtl::Disk.parse('pod34', 'data') }
  end

  def test_disk_parse_rejects_empty_suffix
    assert_raises(ArgumentError) { VMCtl::Disk.parse('pod34', ':50G') }
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb -n test_disk_parse_basic`
Expected: FAIL (`undefined method 'parse' for VMCtl::Disk`).

- [ ] **Step 3: Implement**

In `lib/vmctl/config.rb`, give `Disk` a block with a `parse` class method:

```ruby
  Disk = Struct.new(:file, :size, :from, keyword_init: true) do
    # spec grammar: "<suffix>:<size>[:from <image>]"
    #   e.g. "zfs:100G" or "data:50G:from gold.raw"
    def self.parse(name, spec)
      body, from = spec.to_s.split(':from ', 2)
      suffix, size = body.to_s.split(':', 2)
      if suffix.to_s.empty? || size.to_s.empty?
        raise ArgumentError, "invalid disk spec #{spec.inspect} (expected suffix:size)"
      end
      new(file: "#{name}-#{suffix}.raw", size: size, from: from)
    end
  end
```

In `lib/vmctl/commands/create.rb`, replace the body of `parse_disk` with a delegation:

```ruby
      def parse_disk(name, spec)
        Disk.parse(name, spec)
      rescue ArgumentError
        raise CommandError, "invalid --disk #{spec.inspect} (expected suffix:size)"
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb && ruby -Ilib -Itest test/test_create_command.rb`
Expected: PASS (new Disk.parse tests + existing create tests including the malformed-`--disk` ones).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config.rb lib/vmctl/commands/create.rb test/test_config.rb
git commit -m "$(printf 'refactor: extract Disk.parse grammar for reuse by modify commands\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 8: `add-disk` command (+ `note_next_boot` helper)

**Files:**
- Create: `lib/vmctl/commands/add_disk.rb`
- Modify: `lib/vmctl/commands/base.rb` (add `note_next_boot` helper), `lib/vmctl/cli.rb`
- Test: `test/test_add_disk_command.rb`

**Interfaces:**
- Consumes: `Disk.parse`, `Provisioner#create_disk`, `Config#save`, `vm_for`.
- Produces (in `Commands::Base`, protected): `note_next_boot(vm, what)` → prints `note: <name> is running; <what> takes effect on next start` iff `vm.running?(executor)`. Reused by Tasks 9–11.

- [ ] **Step 1: Write the failing tests**

Create `test/test_add_disk_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_add_disk_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/add_disk'

class TestAddDiskCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @vm_root = File.join(@dir, 'vms')
    @image_dir = File.join(@dir, 'images'); FileUtils.mkdir_p(@image_dir)
    File.write(File.join(@image_dir, 'gold.raw'), 'x' * 1024)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        config_dir: #{@dir}
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        link_base: 10
        image_dir: #{@image_dir}
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_add_disk_creates_file_and_persists
    exec = stopped
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data:50G']) }
    assert_includes exec.runs, "truncate -s 50G #{File.join(@vm_root, 'pod34', 'pod34-data.raw')}"
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal %w[pod34-root.raw pod34-data.raw], entry.disks.map(&:file)
  end

  def test_add_disk_from_image
    exec = stopped
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data:50G:from gold.raw']) }
    assert(exec.runs.any? { |c| c.include?('cp ') && c.include?('gold.raw') })
  end

  def test_add_disk_rejects_duplicate_suffix
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'root:20G']) }
    assert_match(/already has disk/, err.message)
  end

  def test_add_disk_rejects_ninth_disk
    eight = (0...8).map { |i| "{ file: pod34-d#{i}.raw, size: 1G }" }.join(', ')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: #{@vm_root}, zpool: tank, link_base: 10, image_dir: #{@image_dir} }
      vms:
        pod34:
          network: n
          link: 10
          disks: [#{eight}]
    YAML
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data:1G']) }
    assert_match(/8 disks/, err.message)
  end

  def test_add_disk_rejects_bad_size
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data:bogus']) }
  end

  def test_add_disk_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'data:50G']) }
    assert_match(/next start/, out)
  end

  def test_add_disk_dry_run_does_not_persist
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data:50G']) }
    assert_equal before, File.read(@inv)
  end

  def test_add_disk_unknown_vm
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', 'data:50G']) }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_add_disk_command.rb -n test_add_disk_creates_file_and_persists`
Expected: FAIL (`cannot load such file -- vmctl/commands/add_disk`).

- [ ] **Step 3: Implement the helper, the command, and CLI wiring**

In `lib/vmctl/commands/base.rb`, add a protected helper (below `validate_iso_pairing!`):

```ruby
      # Print a "takes effect on next start" notice when the VM is running.
      # All modify commands edit the inventory, which is re-rendered at start.
      def note_next_boot(vm, what)
        return unless vm.running?(executor)
        puts "note: #{vm.name} is running; #{what} takes effect on next start"
      end
```

Create `lib/vmctl/commands/add_disk.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/add_disk.rb
require_relative 'base'
require_relative '../provisioner'
require_relative '../sizes'

module VMCtl
  module Commands
    # add-disk <vm> <suffix>:<size>[:from <image>]
    # Provisions a new raw disk and appends it to the VM's inventory.
    class AddDisk < Base
      def call(args)
        name = args.shift
        spec = args.shift
        unless name && spec
          raise CommandError, 'add-disk requires <vm> <suffix>:<size>[:from image]'
        end
        vm = vm_for(name)
        disk = parse_spec(name, spec)
        validate!(vm, disk)
        provisioner.create_disk(File.join(vm.dir, disk.file), disk.size, from: disk.from)
        vm.entry.disks << disk
        config.save(config.path) unless executor.dry_run?
        puts "added disk #{disk.file} (#{disk.size}) to #{name}"
        note_next_boot(vm, 'the new disk')
      end

      private

      def provisioner
        @provisioner ||= Provisioner.new(executor, config.defaults)
      end

      def parse_spec(name, spec)
        Disk.parse(name, spec)
      rescue ArgumentError => e
        raise CommandError, e.message
      end

      def validate!(vm, disk)
        if vm.entry.disks.any? { |d| d.file == disk.file }
          raise CommandError, "#{vm.name} already has disk #{disk.file}"
        end
        if vm.entry.disks.length >= 8
          raise CommandError, "#{vm.name} already has 8 disks (pci.0.3 slot full)"
        end
        begin
          requested = Sizes.parse(disk.size)
        rescue ArgumentError
          raise CommandError, "invalid size #{disk.size.inspect}"
        end
        return unless disk.from
        image = provisioner.image_path(disk.from)
        raise CommandError, "image not found: #{image}" unless File.exist?(image)
        if requested < File.size(image)
          raise CommandError, "disk size #{disk.size} is smaller than image #{disk.from}"
        end
      end
    end
  end
end
```

In `lib/vmctl/cli.rb`: add `require_relative 'commands/add_disk'` (with the other command requires), add `'add-disk' => Commands::AddDisk` to `COMMANDS`, and add a usage line under Commands:

```
    add-disk <name> <spec>  Add a disk (suffix:size[:from img]) to an existing VM.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_add_disk_command.rb`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/add_disk.rb lib/vmctl/commands/base.rb lib/vmctl/cli.rb test/test_add_disk_command.rb
git commit -m "$(printf 'feat: add-disk command to attach a disk to an existing VM\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 9: `grow-disk` command (+ `Provisioner#grow_disk`, `disk_for` helper)

**Files:**
- Create: `lib/vmctl/commands/grow_disk.rb`
- Modify: `lib/vmctl/provisioner.rb`, `lib/vmctl/commands/base.rb` (add `disk_for`), `lib/vmctl/cli.rb`
- Test: `test/test_provisioner.rb`, `test/test_grow_disk_command.rb`

**Interfaces:**
- Produces: `Provisioner#grow_disk(path, size)` → runs `truncate -s <size> <path>`. `Commands::Base#disk_for(vm, suffix)` → finds the `Disk` whose file is `<name>-<suffix>.raw`, raising `CommandError` if absent. Reused by Task 10.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_provisioner.rb` (match its existing `FakeExecutor`/setup style):

```ruby
  def test_grow_disk_runs_truncate
    exec = FakeExecutor.new
    prov = VMCtl::Provisioner.new(exec, nil)
    prov.grow_disk('/bhyve/pod34/pod34-data.raw', '100G')
    assert_includes exec.runs, 'truncate -s 100G /bhyve/pod34/pod34-data.raw'
  end
```

Create `test/test_grow_disk_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_grow_disk_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/grow_disk'

class TestGrowDiskCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @vm_root = File.join(@dir, 'vms')
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: #{@vm_root}, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: n
          link: 10
          disks:
            - { file: pod34-root.raw, size: 20G }
            - { file: pod34-data.raw, size: 50G }
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_grow_disk_truncates_and_persists
    exec = stopped
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data', '100G']) }
    assert_includes exec.runs, "truncate -s 100G #{File.join(@vm_root, 'pod34', 'pod34-data.raw')}"
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal '100G', entry.disks.find { |d| d.file == 'pod34-data.raw' }.size
  end

  def test_grow_disk_rejects_shrink
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data', '10G']) }
    assert_match(/not larger/, err.message)
  end

  def test_grow_disk_unknown_suffix
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'ghost', '100G']) }
    assert_match(/no disk/, err.message)
  end

  def test_grow_disk_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'data', '100G']) }
    assert_match(/next start/, out)
  end

  def test_grow_disk_requires_three_args
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data']) }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_grow_disk_command.rb -n test_grow_disk_truncates_and_persists`
Expected: FAIL (`cannot load such file -- vmctl/commands/grow_disk`).

- [ ] **Step 3: Implement**

In `lib/vmctl/provisioner.rb`, add a public method (after `create_disk`):

```ruby
    # Grow an existing raw disk in place. Caller validates new > current.
    def grow_disk(path, size)
      @exec.run("truncate -s #{size} #{path}")
    end
```

In `lib/vmctl/commands/base.rb`, add a protected helper (below `note_next_boot`):

```ruby
      # Resolve a disk on a VM by its suffix (file is "<name>-<suffix>.raw").
      def disk_for(vm, suffix)
        file = "#{vm.name}-#{suffix}.raw"
        disk = vm.entry.disks.find { |d| d.file == file }
        raise CommandError, "#{vm.name} has no disk '#{suffix}'" unless disk
        disk
      end
```

Create `lib/vmctl/commands/grow_disk.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/grow_disk.rb
require_relative 'base'
require_relative '../provisioner'
require_relative '../sizes'

module VMCtl
  module Commands
    # grow-disk <vm> <suffix> <new-size>  (grow-only; never shrinks)
    class GrowDisk < Base
      def call(args)
        name, suffix, new_size = args.shift(3)
        unless name && suffix && new_size
          raise CommandError, 'grow-disk requires <vm> <suffix> <new-size>'
        end
        vm = vm_for(name)
        disk = disk_for(vm, suffix)
        validate_grow!(disk, new_size)
        Provisioner.new(executor, config.defaults)
                   .grow_disk(File.join(vm.dir, disk.file), new_size)
        disk.size = new_size
        config.save(config.path) unless executor.dry_run?
        puts "grew #{disk.file} to #{new_size} (grow the guest filesystem after reboot)"
        note_next_boot(vm, 'the larger disk')
      end

      private

      def validate_grow!(disk, new_size)
        begin
          requested = Sizes.parse(new_size)
        rescue ArgumentError
          raise CommandError, "invalid size #{new_size.inspect}"
        end
        return if requested > Sizes.parse(disk.size)
        raise CommandError,
              "new size #{new_size} is not larger than current #{disk.size}"
      end
    end
  end
end
```

In `lib/vmctl/cli.rb`: add `require_relative 'commands/grow_disk'`, register `'grow-disk' => Commands::GrowDisk`, and add a usage line:

```
    grow-disk <name> <sfx> <size>  Grow a disk and update the inventory.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_provisioner.rb && ruby -Ilib -Itest test/test_grow_disk_command.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/grow_disk.rb lib/vmctl/provisioner.rb lib/vmctl/commands/base.rb lib/vmctl/cli.rb test/test_provisioner.rb test/test_grow_disk_command.rb
git commit -m "$(printf 'feat: grow-disk command to enlarge a disk and update inventory\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 10: `remove-disk` command

**Files:**
- Create: `lib/vmctl/commands/remove_disk.rb`
- Modify: `lib/vmctl/cli.rb`
- Test: `test/test_remove_disk_command.rb`

**Interfaces:**
- Consumes: `disk_for`, `note_next_boot`, `Config#save`, `VM#running?`.
- Produces: `remove-disk <vm> <suffix> [--purge]`; refuses to remove `root`; refuses `--purge` while running.

- [ ] **Step 1: Write the failing tests**

Create `test/test_remove_disk_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_remove_disk_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/remove_disk'

class TestRemoveDiskCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @vm_root = File.join(@dir, 'vms')
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: #{@vm_root}, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: n
          link: 10
          disks:
            - { file: pod34-root.raw, size: 20G }
            - { file: pod34-data.raw, size: 50G }
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_remove_disk_drops_entry_keeps_file
    exec = stopped
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'data']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal %w[pod34-root.raw], entry.disks.map(&:file)
    refute(exec.runs.any? { |c| c.start_with?('rm ') })
    assert_match(/left in place/, out)
  end

  def test_remove_disk_purge_deletes_file
    exec = stopped
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data', '--purge']) }
    assert_includes exec.runs, "rm -f #{File.join(@vm_root, 'pod34', 'pod34-data.raw')}"
  end

  def test_remove_disk_refuses_root
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'root']) }
    assert_match(/root/, err.message)
  end

  def test_remove_disk_purge_refused_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data', '--purge']) }
    assert_match(/running/, err.message)
  end

  def test_remove_disk_unknown_suffix
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'ghost']) }
  end

  def test_remove_disk_requires_two_args
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_remove_disk_command.rb -n test_remove_disk_drops_entry_keeps_file`
Expected: FAIL (`cannot load such file -- vmctl/commands/remove_disk`).

- [ ] **Step 3: Implement**

Create `lib/vmctl/commands/remove_disk.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/remove_disk.rb
require 'optparse'
require_relative 'base'

module VMCtl
  module Commands
    # remove-disk <vm> <suffix> [--purge]
    # Drops a disk from the inventory; --purge also deletes the backing file.
    class RemoveDisk < Base
      def call(args)
        purge = false
        parser = OptionParser.new { |p| p.on('--purge') { purge = true } }
        rest = parser.parse(args)
        name, suffix = rest.shift(2)
        raise CommandError, 'remove-disk requires <vm> <suffix>' unless name && suffix
        raise CommandError, "refusing to remove the root disk of #{name}" if suffix == 'root'
        vm = vm_for(name)
        disk = disk_for(vm, suffix)
        if purge && vm.running?(executor)
          raise CommandError,
                "#{name} is running; stop it before --purge (cannot delete an in-use disk)"
        end
        vm.entry.disks.delete(disk)
        detail = purge ? purge_file(vm, disk) : "(file #{disk.file} left in place)"
        config.save(config.path) unless executor.dry_run?
        puts "removed disk #{disk.file} from #{name} #{detail}"
        note_next_boot(vm, 'the disk removal')
      end

      private

      def purge_file(vm, disk)
        executor.run("rm -f #{File.join(vm.dir, disk.file)}")
        'and purged its file'
      end
    end
  end
end
```

In `lib/vmctl/cli.rb`: add `require_relative 'commands/remove_disk'`, register `'remove-disk' => Commands::RemoveDisk`, and add a usage line:

```
    remove-disk <name> <sfx> [--purge]  Remove a disk (optionally delete the file).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_remove_disk_command.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/remove_disk.rb lib/vmctl/cli.rb test/test_remove_disk_command.rb
git commit -m "$(printf 'feat: remove-disk command (--purge deletes the backing file)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 11: `set` command

**Files:**
- Create: `lib/vmctl/commands/set.rb`
- Modify: `lib/vmctl/cli.rb`
- Test: `test/test_set_command.rb`

**Interfaces:**
- Consumes: `Netgraph#ensure_bridge!`, `Allocator#generate_mac`, `validate_iso_pairing!`, `note_next_boot`, `Config#save`.
- Produces: `set <vm> [--autostart|--no-autostart] [--network NET] [--mac MAC|generate] [--config TMPL] [--iso FILE|--no-iso]`.

- [ ] **Step 1: Write the failing tests**

Create `test/test_set_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_set_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/set'

class TestSetCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, 'pod.conf'), "cpus=2\n")
    File.write(File.join(@dir, 'inst.conf'), "pci.0.5.0.port.0.path=%(iso)\n")
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          autostart: false
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped(extra = {}) = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false }.merge(extra))
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_set_autostart
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--autostart']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').autostart
  end

  def test_set_no_autostart
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-autostart']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').autostart
  end

  def test_set_network_checks_bridge
    exec = stopped('ngctl info newnet:' => true)
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--network', 'newnet']) }
    assert_equal 'newnet', VMCtl::Config.load(@inv).vms.fetch('pod34').network
  end

  def test_set_network_fails_when_bridge_missing
    exec = stopped('ngctl info newnet:' => false)
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod34', '--network', 'newnet']) }
  end

  def test_set_mac_generate
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--mac', 'generate']) }
    mac = VMCtl::Config.load(@inv).vms.fetch('pod34').mac
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, mac)
  end

  def test_set_config_validates_template
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--config', 'nope.conf']) }
    assert_match(/template not found/, err.message)
  end

  def test_set_iso_requires_pairing
    # pod.conf has no %(iso); setting an iso on it must fail pairing.
    iso = File.join(@dir, 'x.iso'); File.write(iso, 'i')
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--iso', iso]) }
    assert_match(/does not reference/, err.message)
  end

  def test_set_iso_with_installer_template
    iso = File.join(@dir, 'x.iso'); File.write(iso, 'i')
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--config', 'inst.conf', '--iso', iso]) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal iso, entry.iso
    assert_equal 'inst.conf', entry.config
  end

  def test_set_no_iso_clears
    iso = File.join(@dir, 'x.iso'); File.write(iso, 'i')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: inst.conf
          network: labs_vlan50
          link: 10
          iso: #{iso}
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-iso']) }
    assert_nil VMCtl::Config.load(@inv).vms.fetch('pod34').iso
  end

  def test_set_requires_a_field
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end

  def test_set_warns_when_running
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: FakeExecutor.new(probes: { '/dev/vmm/pod34' => true }))
    out = capture_stdout { cmd.call(['pod34', '--autostart']) }
    assert_match(/next start/, out)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_set_command.rb -n test_set_autostart`
Expected: FAIL (`cannot load such file -- vmctl/commands/set`).

- [ ] **Step 3: Implement**

Create `lib/vmctl/commands/set.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/set.rb
require 'optparse'
require_relative 'base'
require_relative '../netgraph'
require_relative '../allocator'

module VMCtl
  module Commands
    # set <vm> [field flags]  -- edit scalar inventory fields.
    class Set < Base
      def call(args)
        opts = {}
        parser = OptionParser.new do |p|
          p.on('--autostart')    { opts[:autostart] = true }
          p.on('--no-autostart') { opts[:autostart] = false }
          p.on('--network NET')  { |v| opts[:network] = v }
          p.on('--mac MAC')      { |v| opts[:mac] = v }
          p.on('--config TMPL')  { |v| opts[:config] = v }
          p.on('--iso FILE')     { |v| opts[:iso] = v }
          p.on('--no-iso')       { opts[:iso] = false }
        end
        rest = parser.parse(args)
        name = rest.shift
        raise CommandError, 'set requires a VM name' unless name
        raise CommandError, 'set requires at least one field to change' if opts.empty?
        vm = vm_for(name)
        changed = apply!(vm, opts)
        config.save(config.path) unless executor.dry_run?
        puts "updated #{name}: #{changed.join(', ')}"
        note_next_boot(vm, 'these changes')
      end

      private

      def apply!(vm, opts)
        e = vm.entry
        changed = []
        if opts.key?(:autostart)
          e.autostart = opts[:autostart]
          changed << "autostart=#{e.autostart}"
        end
        if opts.key?(:network)
          Netgraph.new(executor).ensure_bridge!(opts[:network])
          e.network = opts[:network]
          changed << "network=#{e.network}"
        end
        if opts.key?(:mac)
          e.mac = resolve_mac(opts[:mac], vm.name)
          changed << "mac=#{e.mac}"
        end
        if opts.key?(:config)
          validate_template!(opts[:config])
          e.config = opts[:config]
          changed << "config=#{e.config}"
        end
        apply_iso!(vm, opts[:iso], changed) if opts.key?(:iso)
        changed
      end

      def resolve_mac(mac, name)
        return Allocator.new(config).generate_mac(name) if mac == 'generate'
        mac
      end

      def validate_template!(tmpl)
        path = File.join(config.defaults.config_dir, tmpl)
        raise CommandError, "template not found: #{path}" unless File.exist?(path)
      end

      def apply_iso!(vm, iso, changed)
        e = vm.entry
        if iso == false
          e.iso = nil
          changed << 'iso=(none)'
        else
          path = File.expand_path(iso)
          raise CommandError, "iso not found: #{path}" unless File.exist?(path)
          e.iso = path
          changed << "iso=#{path}"
        end
        validate_iso_pairing!(vm)
      end
    end
  end
end
```

In `lib/vmctl/cli.rb`: add `require_relative 'commands/set'`, register `'set' => Commands::Set`, and add a usage line:

```
    set <name> [opts]       Change VM fields (--autostart/--network/--mac/--config/--iso).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_set_command.rb`
Expected: PASS.

- [ ] **Step 5: Run the FULL suite + commit**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS (entire suite).

```bash
git add lib/vmctl/commands/set.rb lib/vmctl/cli.rb test/test_set_command.rb
git commit -m "$(printf 'feat: set command to edit scalar VM inventory fields\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] Run the full suite once more: `ruby -Ilib -Itest test/run_all.rb` → all PASS.
- [ ] Sanity-check the CLI help lists the four new commands: `ruby -Ilib bin/vmctl help`.
- [ ] Confirm `git log --oneline` shows the 11 task commits on `feat/dynamic-configs-modify`.

## Notes for the implementer

- `FakeExecutor#run`/`#capture` return canned strings keyed by substring; `#success?` answers `probes` (defaults to `true` for unspecified probes — always set `'/dev/vmm/<name>' => false` when you need a "stopped" VM, or the modify commands will print the running-notice).
- `Config#save` is atomic (temp file + rename) and writes the whole inventory; the modify commands mutate the in-memory `VMEntry`/`disks` then call `config.save(config.path)`. `Disk` is a `Struct`, so `disk.size = ...` mutates the same object held in `entry.disks`.
- Dry-run: gate **only** `config.save` behind `unless executor.dry_run?`. `Executor#run` already no-ops under dry-run in production, and `FakeExecutor` records calls regardless, so tests assert on `exec.runs` even in dry-run.
- Disk index 0 is root; `remove-disk` refuses suffix `root`. There is no guard preventing `grow-disk root` (growing the root disk is fine).
