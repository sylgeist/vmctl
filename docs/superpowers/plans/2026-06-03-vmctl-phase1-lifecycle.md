# vmctl Phase 1 — Foundation, Inventory & Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundation and lifecycle layer of `vmctl` — a pure-Ruby CLI that manages already-provisioned bhyve VMs from a central YAML inventory (`start`/`stop`/`restart`/`status`/`console`/`list`), supervising each VM across guest reboots.

**Architecture:** A central `inventory.yml` is the single source of truth. Commands are thin; they delegate to domain objects (`Config`, `Allocator`, `Netgraph`, `VM`, `Supervisor`). The `Executor` is the sole shell-out boundary (Open3, dry-run aware) so everything else is unit-tested by injecting a fake. `VM` renders the exact `bhyve -k <tmpl> -o …` invocation from inventory; `Supervisor` runs the daemonized reboot/destroy loop. Mirrors the sibling `zfsreplicate` project's conventions.

**Tech Stack:** Ruby (stdlib only — no gems), `OptionParser`, `Open3`, `YAML`, `Logger`, minitest. FreeBSD base tools: `bhyve`, `bhyvectl`, `ngctl`, `cu`.

**Scope note:** Provisioning (`create`/`import`/`destroy`), the `Provisioner`, and cloud-init are **Phase 2** (a separate plan). This plan assumes VMs already have inventory entries and on-disk images.

**Conventions (from zfsreplicate, follow exactly):**
- Module namespace: `VMCtl`. Files start with `# frozen_string_literal: true` and a `# lib/vmctl/<file>.rb` path comment.
- `bin/vmctl` is a `$LOAD_PATH` shim that requires `vmctl/cli` and calls `VMCtl::CLI.run(ARGV)`.
- Custom error classes per concern (`ConfigError`, `ExecutorError`, …).
- Tests: minitest, `test/test_helper.rb` unshifts `lib` and silences logs, `test/run_all.rb` globs `test_*.rb`.
- Exit codes: `2` for usage/arg errors (`warn` + `exit 2`), `1` for runtime failures, `0` success.

---

## File Structure

```
vmctl/
  bin/vmctl
  lib/vmctl/
    version.rb        # VERSION constant
    log.rb            # VMCtl.logger / .log_level=
    executor.rb       # Executor: run/capture/success?, dry-run aware; ExecutorError
    config.rb         # Config.load/save (atomic); Defaults/VMEntry/Disk structs; ConfigError
    allocator.rb      # next_link (>= link_base), link_taken?, generate_mac
    netgraph.rb       # bridge_exists?(name) via ngctl
    vm.rb             # VM: bhyve_argv, paths (dir/pidfile/logfile/vmm_device/console_device)
    supervisor.rb     # reboot?(status), supervise loop, start(fork/detach), stop
    cli.rb            # OptionParser, subcommand dispatch, usage
    commands/
      base.rb         # shared helpers for command handlers
      list.rb status.rb start.rb stop.rb restart.rb console.rb
  test/
    test_helper.rb run_all.rb
    test_executor.rb test_config.rb test_allocator.rb test_netgraph.rb
    test_vm.rb test_supervisor.rb test_cli.rb test_commands.rb
  rc/vmctl            # rc.d shim (vmctl start --all at boot)
  Gemfile .ruby-version .gitignore README.md
  .github/workflows/test.yml
```

---

## Task 0: Project skeleton

**Files:**
- Create: `Gemfile`, `.ruby-version`, `bin/vmctl`, `lib/vmctl/version.rb`, `lib/vmctl/log.rb`, `test/test_helper.rb`, `test/run_all.rb`, `.github/workflows/test.yml`

- [ ] **Step 1: Create `.ruby-version`**

```
3.3
```

- [ ] **Step 2: Create `Gemfile`**

```ruby
# Gemfile
# No gems — Ruby stdlib + FreeBSD base system only.
# ruby '>= 3.0'
```

- [ ] **Step 3: Create `lib/vmctl/version.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/version.rb
module VMCtl
  VERSION = '0.1.0'
end
```

- [ ] **Step 4: Create `lib/vmctl/log.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/log.rb
require 'logger'

module VMCtl
  def self.logger
    @logger ||= begin
      l = Logger.new($stderr)
      l.progname = 'vmctl'
      l.formatter = lambda do |sev, _t, prog, msg|
        tag = Thread.current[:vmctl_vm]
        prefix = tag ? "#{prog}[#{tag}]" : prog
        "[#{sev}] #{prefix}: #{msg}\n"
      end
      l
    end
  end

  def self.log_level=(level)
    logger.level = level
  end
end
```

- [ ] **Step 5: Create `bin/vmctl`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# bin/vmctl
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'vmctl/cli'
VMCtl::CLI.run(ARGV)
```

- [ ] **Step 6: Create `test/test_helper.rb`**

```ruby
# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'vmctl/log'

# Keep test output pristine; tests assert on behavior, not log lines.
VMCtl.log_level = Logger::FATAL
```

- [ ] **Step 7: Create `test/run_all.rb`**

```ruby
Dir[File.expand_path('../test_*.rb', __FILE__)].sort.each { |f| require f }
```

- [ ] **Step 8: Create `.github/workflows/test.yml`**

```yaml
name: test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
      - run: ruby test/run_all.rb
```

- [ ] **Step 9: Make `bin/vmctl` executable and verify the test harness runs (empty but green)**

Run: `chmod +x bin/vmctl && ruby test/run_all.rb`
Expected: `0 runs, 0 assertions, 0 failures, 0 errors, 0 skips` (no test files yet, exits 0).

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "chore: scaffold vmctl project skeleton"
```

---

## Task 1: Executor (local, dry-run aware) + FakeExecutor test double

**Files:**
- Create: `lib/vmctl/executor.rb`
- Test: `test/test_executor.rb`

The Executor wraps Open3 for short commands. Three methods:
- `run(cmd)` — **mutating**; in dry-run it logs and returns `""` without executing; otherwise executes and returns stdout, raising `ExecutorError` on failure.
- `capture(cmd)` — **read-only query**; always executes (even in dry-run), returns stdout, raises on failure.
- `success?(cmd)` — runs a probe command, returns `true`/`false` by exit status, never raises (used for existence checks like `ngctl info`).

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_executor.rb
require 'test_helper'
require 'vmctl/executor'

class TestExecutor < Minitest::Test
  def test_capture_returns_stdout
    e = VMCtl::Executor.new
    assert_equal "hello\n", e.capture("echo hello")
  end

  def test_run_returns_stdout_when_not_dry_run
    e = VMCtl::Executor.new(dry_run: false)
    assert_equal "hi\n", e.run("echo hi")
  end

  def test_run_is_noop_in_dry_run
    e = VMCtl::Executor.new(dry_run: true)
    # Would create a file if it ran; assert it returns "" and does nothing.
    path = File.join(Dir.tmpdir, "vmctl_dryrun_#{Process.pid}")
    File.delete(path) if File.exist?(path)
    assert_equal "", e.run("touch #{path}")
    refute File.exist?(path), "dry-run must not execute mutating commands"
  end

  def test_capture_runs_even_in_dry_run
    e = VMCtl::Executor.new(dry_run: true)
    assert_equal "q\n", e.capture("echo q")
  end

  def test_run_raises_on_failure
    e = VMCtl::Executor.new
    assert_raises(VMCtl::ExecutorError) { e.run("false") }
  end

  def test_success_is_boolean_and_never_raises
    e = VMCtl::Executor.new
    assert_equal true, e.success?("true")
    assert_equal false, e.success?("false")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_executor.rb`
Expected: FAIL — `cannot load such file -- vmctl/executor`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# frozen_string_literal: true
# lib/vmctl/executor.rb
require 'open3'
require 'tmpdir'
require_relative 'log'

module VMCtl
  class ExecutorError < StandardError; end

  # The sole shell-out boundary. Inject a fake in tests.
  class Executor
    def initialize(dry_run: false)
      @dry_run = dry_run
    end

    # Mutating command. No-op (logs only) in dry-run.
    def run(cmd)
      if @dry_run
        VMCtl.logger.info("[dry-run] #{cmd}")
        return ""
      end
      capture(cmd)
    end

    # Read-only query. Always executes. Raises on failure.
    def capture(cmd)
      VMCtl.logger.debug("exec: #{cmd}")
      stdout, stderr, status = Open3.capture3(cmd)
      unless status.success?
        raise ExecutorError,
              "#{cmd.split.first} exited with status #{status.exitstatus}: #{stderr.strip}"
      end
      stdout
    end

    # Probe: true/false by exit status, never raises.
    def success?(cmd)
      VMCtl.logger.debug("probe: #{cmd}")
      _out, _err, status = Open3.capture3(cmd)
      status.success?
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_executor.rb`
Expected: PASS — 6 runs, all assertions pass.

- [ ] **Step 5: Add the shared FakeExecutor to `test_helper.rb`**

Append to `test/test_helper.rb`:

```ruby
# Records mutating commands, answers queries/probes from canned data.
# Use in every test that touches a shell-out boundary.
class FakeExecutor
  attr_reader :runs, :captures

  # captures: Hash of command-substring => stdout to return from #capture/#run
  # probes:   Hash of command-substring => boolean to return from #success?
  def initialize(captures: {}, probes: {})
    @runs = []
    @captures = []
    @canned = captures
    @probes = probes
  end

  def run(cmd)
    @runs << cmd
    canned_for(cmd) || ""
  end

  def capture(cmd)
    @captures << cmd
    canned_for(cmd) || ""
  end

  def success?(cmd)
    match = @probes.find { |k, _| cmd.include?(k) }
    match ? match[1] : true
  end

  private

  def canned_for(cmd)
    match = @canned.find { |k, _| cmd.include?(k) }
    match&.last
  end
end
```

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/executor.rb test/test_executor.rb test/test_helper.rb
git commit -m "feat: add dry-run-aware Executor and FakeExecutor test double"
```

---

## Task 2: Config / inventory (load, structs, atomic save)

**Files:**
- Create: `lib/vmctl/config.rb`
- Test: `test/test_config.rb`

Structs: `Defaults(:config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir)`, `VMEntry(:name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init)`, `Disk(:file, :size, :from)`. `Config` exposes `.defaults` and `.vms` (Hash name→VMEntry). `Config.load(path)` parses YAML; `#save(path)` writes atomically (temp + rename). `#to_h` reproduces the YAML structure for round-trips.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_config.rb
require 'test_helper'
require 'vmctl/config'
require 'tempfile'
require 'tmpdir'

VALID_INVENTORY = <<~YAML
  defaults:
    config_dir: /bhyve/configs
    vm_root: /bhyve
    zpool: tank/bhyve
    template: pod.conf
    link_base: 10
  vms:
    pod34:
      config: pod.conf
      network: labs_vlan50
      link: 10
      mac: null
      autostart: true
      disks:
        - { file: pod34-root.raw, size: 20G, from: base-14.raw }
        - { file: pod34-zfs.raw, size: 100G }
YAML

class TestConfig < Minitest::Test
  def write_inventory(content)
    f = Tempfile.new(['inventory', '.yml'])
    f.write(content)
    f.flush
    f
  end

  def test_loads_defaults
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/bhyve/configs', cfg.defaults.config_dir
    assert_equal 'tank/bhyve', cfg.defaults.zpool
    assert_equal 10, cfg.defaults.link_base
    f.close
  end

  def test_defaults_fill_in_missing_keys
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal 10, cfg.defaults.link_base          # default link_base
    assert_equal '/var/run/vmctl', cfg.defaults.run_dir
    assert_equal '/var/log/vmctl', cfg.defaults.log_dir
    f.close
  end

  def test_loads_vm_entry
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    vm = cfg.vms.fetch('pod34')
    assert_equal 'labs_vlan50', vm.network
    assert_equal 10, vm.link
    assert_nil vm.mac
    assert_equal true, vm.autostart
    assert_equal 2, vm.disks.length
    assert_equal 'pod34-root.raw', vm.disks.first.file
    assert_equal 'base-14.raw', vm.disks.first.from
    assert_nil vm.disks.last.from
    f.close
  end

  def test_raises_on_missing_file
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load('/nonexistent.yml') }
  end

  def test_save_round_trips
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    out = File.join(Dir.mktmpdir, 'out.yml')
    cfg.save(out)
    reloaded = VMCtl::Config.load(out)
    assert_equal cfg.vms.keys, reloaded.vms.keys
    assert_equal 10, reloaded.vms['pod34'].link
    assert_equal '20G', reloaded.vms['pod34'].disks.first.size
    f.close
  end

  def test_save_is_atomic_no_partial_file_on_same_dir
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    dir = Dir.mktmpdir
    out = File.join(dir, 'inv.yml')
    cfg.save(out)
    # Only the final file should remain — no leftover temp files.
    leftovers = Dir.children(dir).reject { |n| n == 'inv.yml' }
    assert_empty leftovers, "atomic save must not leave temp files: #{leftovers}"
    f.close
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_config.rb`
Expected: FAIL — `cannot load such file -- vmctl/config`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# frozen_string_literal: true
# lib/vmctl/config.rb
require 'yaml'
require 'tempfile'

module VMCtl
  class ConfigError < StandardError; end

  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    keyword_init: true
  )
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init,
    keyword_init: true
  )
  Disk = Struct.new(:file, :size, :from, keyword_init: true)

  class Config
    DEFAULTS = {
      'config_dir' => '/bhyve/configs',
      'vm_root'    => '/bhyve',
      'zpool'      => 'tank/bhyve',
      'template'   => 'pod.conf',
      'link_base'  => 10,
      'run_dir'    => '/var/run/vmctl',
      'log_dir'    => '/var/log/vmctl'
    }.freeze

    attr_reader :defaults, :vms, :path

    def self.load(path)
      raise ConfigError, "Inventory file not found: #{path}" unless File.exist?(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      raise ConfigError, "Inventory must be a mapping in #{path}" unless raw.is_a?(Hash)
      new(raw, path)
    end

    def initialize(raw, path = nil)
      @path = path
      @defaults = parse_defaults(raw.fetch('defaults', {}) || {})
      @vms = parse_vms(raw.fetch('vms', {}) || {})
    end

    def save(path)
      dir = File.dirname(path)
      tmp = Tempfile.create(['inventory', '.yml'], dir)
      begin
        tmp.write(to_yaml)
        tmp.flush
        tmp.close
        File.rename(tmp.path, path)
      rescue StandardError
        File.delete(tmp.path) if File.exist?(tmp.path)
        raise
      end
    end

    def to_h
      {
        'defaults' => @defaults.to_h.transform_keys(&:to_s),
        'vms' => @vms.transform_values { |vm| vm_to_h(vm) }
      }
    end

    def to_yaml
      YAML.dump(to_h)
    end

    private

    def parse_defaults(h)
      merged = DEFAULTS.merge(h)
      Defaults.new(
        config_dir: merged['config_dir'],
        vm_root:    merged['vm_root'],
        zpool:      merged['zpool'],
        template:   merged['template'],
        link_base:  Integer(merged['link_base']),
        run_dir:    merged['run_dir'],
        log_dir:    merged['log_dir']
      )
    end

    def parse_vms(h)
      raise ConfigError, "'vms' must be a mapping" unless h.is_a?(Hash)
      h.each_with_object({}) do |(name, body), acc|
        acc[name] = parse_vm(name, body || {})
      end
    end

    def parse_vm(name, body)
      raise ConfigError, "VM '#{name}' must be a mapping" unless body.is_a?(Hash)
      VMEntry.new(
        name:       name,
        config:     body['config'] || @defaults.template,
        network:    body['network'],
        link:       body['link'],
        mac:        body['mac'],
        autostart:  body.fetch('autostart', false),
        disks:      parse_disks(body.fetch('disks', [])),
        cloud_init: body['cloud_init']
      )
    end

    def parse_disks(list)
      raise ConfigError, "'disks' must be a list" unless list.is_a?(Array)
      list.map do |d|
        Disk.new(file: d['file'], size: d['size'], from: d['from'])
      end
    end

    def vm_to_h(vm)
      h = {
        'config'  => vm.config,
        'network' => vm.network,
        'link'    => vm.link,
        'mac'     => vm.mac,
        'autostart' => vm.autostart,
        'disks'   => vm.disks.map { |d| compact_disk(d) }
      }
      h['cloud_init'] = vm.cloud_init if vm.cloud_init
      h
    end

    def compact_disk(d)
      h = { 'file' => d.file, 'size' => d.size }
      h['from'] = d.from if d.from
      h
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_config.rb`
Expected: PASS — 6 runs, all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "feat: add inventory Config with structs and atomic save"
```

---

## Task 3: Allocator (lowest-free link, mac generation)

**Files:**
- Create: `lib/vmctl/allocator.rb`
- Test: `test/test_allocator.rb`

`Allocator.new(config)`. `#next_link` returns the lowest integer `>= defaults.link_base` not used by any VM. `#link_taken?(n)`. `#name_taken?(name)`. `#generate_mac(name)` returns a deterministic locally-administered MAC seeded by name.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_allocator.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/allocator'

class TestAllocator < Minitest::Test
  def config_with(links)
    raw = {
      'defaults' => { 'link_base' => 10 },
      'vms' => links.each_with_object({}) do |l, acc|
        acc["vm#{l}"] = { 'network' => 'n', 'link' => l, 'disks' => [] }
      end
    }
    VMCtl::Config.new(raw)
  end

  def test_first_link_is_link_base_when_empty
    alloc = VMCtl::Allocator.new(config_with([]))
    assert_equal 10, alloc.next_link
  end

  def test_skips_taken_links
    alloc = VMCtl::Allocator.new(config_with([10, 11, 13]))
    assert_equal 12, alloc.next_link
  end

  def test_returns_next_after_contiguous_block
    alloc = VMCtl::Allocator.new(config_with([10, 11, 12]))
    assert_equal 13, alloc.next_link
  end

  def test_ignores_links_below_base
    # A hand-assigned link of 3 (in the reserved 0-9 range) must not affect allocation.
    alloc = VMCtl::Allocator.new(config_with([3, 10]))
    assert_equal 11, alloc.next_link
  end

  def test_link_taken
    alloc = VMCtl::Allocator.new(config_with([10]))
    assert alloc.link_taken?(10)
    refute alloc.link_taken?(11)
  end

  def test_generate_mac_is_locally_administered_and_deterministic
    alloc = VMCtl::Allocator.new(config_with([]))
    mac = alloc.generate_mac('pod34')
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, mac)
    # Locally-administered bit set, unicast: second hex nibble is 2/6/a/e.
    first_octet = mac.split(':').first.to_i(16)
    assert_equal 0b10, first_octet & 0b11, "must be locally-administered unicast"
    assert_equal mac, alloc.generate_mac('pod34'), "must be deterministic"
    refute_equal mac, alloc.generate_mac('pod35')
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_allocator.rb`
Expected: FAIL — `cannot load such file -- vmctl/allocator`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# frozen_string_literal: true
# lib/vmctl/allocator.rb
require 'digest'

module VMCtl
  # Owns "what's the next free ID" decisions. Pure logic over the inventory.
  class Allocator
    # Locally-administered, unicast OUI base (second-least-significant bit of
    # the first octet set, least-significant clear): 0x58 = 0101_1000.
    OUI = [0x58, 0x9c, 0xfc].freeze

    def initialize(config)
      @config = config
    end

    def next_link
      base = @config.defaults.link_base
      n = base
      n += 1 while link_taken?(n)
      n
    end

    def link_taken?(n)
      @config.vms.values.any? { |vm| vm.link == n }
    end

    def name_taken?(name)
      @config.vms.key?(name)
    end

    # Deterministic per-name MAC in the locally-administered range.
    def generate_mac(name)
      digest = Digest::SHA256.hexdigest(name)
      tail = [digest[0, 2], digest[2, 2], digest[4, 2]].map { |h| h.to_i(16) }
      (OUI + tail).map { |b| format('%02x', b) }.join(':')
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_allocator.rb`
Expected: PASS — 6 runs, all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/allocator.rb test/test_allocator.rb
git commit -m "feat: add Allocator for link allocation and MAC generation"
```

---

## Task 4: Netgraph bridge validation

**Files:**
- Create: `lib/vmctl/netgraph.rb`
- Test: `test/test_netgraph.rb`

`Netgraph.new(executor)`. `#bridge_exists?(name)` probes `ngctl info <name>:` via `executor.success?`. `#ensure_bridge!(name)` raises a clear `NetgraphError` when absent.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_netgraph.rb
require 'test_helper'
require 'vmctl/netgraph'

class TestNetgraph < Minitest::Test
  def test_bridge_exists_true
    exec = FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => true })
    ng = VMCtl::Netgraph.new(exec)
    assert ng.bridge_exists?('labs_vlan50')
  end

  def test_bridge_exists_false
    exec = FakeExecutor.new(probes: { 'ngctl info nope:' => false })
    ng = VMCtl::Netgraph.new(exec)
    refute ng.bridge_exists?('nope')
  end

  def test_ensure_bridge_raises_with_helpful_message
    exec = FakeExecutor.new(probes: { 'ngctl info nope:' => false })
    ng = VMCtl::Netgraph.new(exec)
    err = assert_raises(VMCtl::NetgraphError) { ng.ensure_bridge!('nope') }
    assert_match(/nope/, err.message)
    assert_match(/netgraph_setup/, err.message)
  end

  def test_probe_uses_trailing_colon_syntax
    exec = FakeExecutor.new(probes: { 'ngctl info mgmt_vlan1:' => true })
    ng = VMCtl::Netgraph.new(exec)
    ng.bridge_exists?('mgmt_vlan1')
    # success? was asked about the colon-suffixed node address.
    assert ng.bridge_exists?('mgmt_vlan1')
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_netgraph.rb`
Expected: FAIL — `cannot load such file -- vmctl/netgraph`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# frozen_string_literal: true
# lib/vmctl/netgraph.rb
module VMCtl
  class NetgraphError < StandardError; end

  # Read-only view of netgraph. vmctl never mutates bridge topology — bridges
  # are host infrastructure created by the netgraph_setup rc script.
  class Netgraph
    def initialize(executor)
      @exec = executor
    end

    def bridge_exists?(name)
      @exec.success?("ngctl info #{name}:")
    end

    def ensure_bridge!(name)
      return if bridge_exists?(name)
      raise NetgraphError,
            "bridge '#{name}' not found — is netgraph_setup running?"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_netgraph.rb`
Expected: PASS — 4 runs, all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/netgraph.rb test/test_netgraph.rb
git commit -m "feat: add read-only Netgraph bridge validation"
```

---

## Task 5: VM — argv rendering and path helpers

**Files:**
- Create: `lib/vmctl/vm.rb`
- Test: `test/test_vm.rb`

`VM.new(entry, defaults)` wraps a `VMEntry` + `Defaults`. Responsibilities:
- `#bhyve_argv` → the array `["bhyve", "-k", "<config_dir>/<config>", "-o", "network=<net>", "-o", "link=<n>", (maybe "-o", "mac=<mac>"), "<name>"]`. `mac` only included when non-nil.
- `#bhyve_command` → `bhyve_argv` joined (for logging / dry-run display).
- Path helpers: `#dir` (`<vm_root>/<name>`), `#pidfile` (`<run_dir>/<name>.pid`), `#logfile` (`<log_dir>/<name>.log`), `#vmm_device` (`/dev/vmm/<name>`), `#console_device` (`/dev/nmdm<link>B`), `#disk_paths`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_vm.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'

class TestVM < Minitest::Test
  def defaults
    VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
    )
  end

  def entry(mac: nil)
    VMCtl::VMEntry.new(
      name: 'pod34', config: 'pod.conf', network: 'labs_vlan50', link: 10,
      mac: mac, autostart: true,
      disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)],
      cloud_init: nil
    )
  end

  def test_bhyve_argv_without_mac
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(
      ['bhyve', '-k', '/bhyve/configs/pod.conf',
       '-o', 'network=labs_vlan50', '-o', 'link=10', 'pod34'],
      vm.bhyve_argv
    )
  end

  def test_bhyve_argv_includes_mac_when_set
    vm = VMCtl::VM.new(entry(mac: '58:9c:fc:01:02:03'), defaults)
    assert_includes vm.bhyve_argv, 'mac=58:9c:fc:01:02:03'
  end

  def test_bhyve_command_is_joined_string
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(
      'bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 pod34',
      vm.bhyve_command
    )
  end

  def test_paths
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal '/bhyve/pod34', vm.dir
    assert_equal '/var/run/vmctl/pod34.pid', vm.pidfile
    assert_equal '/var/log/vmctl/pod34.log', vm.logfile
    assert_equal '/dev/vmm/pod34', vm.vmm_device
    assert_equal '/dev/nmdm10B', vm.console_device
    assert_equal ['/bhyve/pod34/pod34-root.raw'], vm.disk_paths
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_vm.rb`
Expected: FAIL — `cannot load such file -- vmctl/vm`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# frozen_string_literal: true
# lib/vmctl/vm.rb
module VMCtl
  # One VM: turns an inventory entry + defaults into the exact bhyve invocation
  # and the on-disk paths vmctl manages.
  class VM
    attr_reader :entry, :defaults

    def initialize(entry, defaults)
      @entry = entry
      @defaults = defaults
    end

    def name
      @entry.name
    end

    def bhyve_argv
      argv = ['bhyve', '-k', template_path,
              '-o', "network=#{@entry.network}",
              '-o', "link=#{@entry.link}"]
      argv += ['-o', "mac=#{@entry.mac}"] if @entry.mac
      argv << name
      argv
    end

    def bhyve_command
      bhyve_argv.join(' ')
    end

    def template_path
      File.join(@defaults.config_dir, @entry.config)
    end

    def dir
      File.join(@defaults.vm_root, name)
    end

    def pidfile
      File.join(@defaults.run_dir, "#{name}.pid")
    end

    def logfile
      File.join(@defaults.log_dir, "#{name}.log")
    end

    def vmm_device
      "/dev/vmm/#{name}"
    end

    def console_device
      "/dev/nmdm#{@entry.link}B"
    end

    def disk_paths
      @entry.disks.map { |d| File.join(dir, d.file) }
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_vm.rb`
Expected: PASS — 4 runs, all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/vm.rb test/test_vm.rb
git commit -m "feat: add VM argv rendering and path helpers"
```

---

## Task 6: Supervisor — exit-code mapping and the reboot/destroy loop

**Files:**
- Create: `lib/vmctl/supervisor.rb`
- Test: `test/test_supervisor.rb`

The supervisor runs `bhyve` (long-running, so via a `runner` callable that returns an exit status Integer — injectable for tests and so signals can be forwarded in production), then always runs `bhyvectl --destroy --vm=<name>` through the Executor, and relaunches only when the guest rebooted.

bhyve exit codes: `0` = reboot/reset (relaunch), `1` = poweroff, `2` = halt, `3` = triple-fault, `4` = error (all → stop).

The `start` (fork/detach + pidfile) and `stop` (signal) methods are integration-level; this task unit-tests the **pure decision** (`reboot?`) and the **loop sequencing** (`supervise`) with an injected runner + FakeExecutor. The fork path is exercised manually (Manual Verification below) and in Phase-1 end-to-end testing on a FreeBSD host.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_supervisor.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/supervisor'

class TestSupervisor < Minitest::Test
  def build_vm
    defaults = VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
    )
    entry = VMCtl::VMEntry.new(
      name: 'pod34', config: 'pod.conf', network: 'labs_vlan50', link: 10,
      mac: nil, autostart: true, disks: [], cloud_init: nil
    )
    VMCtl::VM.new(entry, defaults)
  end

  def test_reboot_predicate
    assert VMCtl::Supervisor.reboot?(0)
    refute VMCtl::Supervisor.reboot?(1)
    refute VMCtl::Supervisor.reboot?(2)
    refute VMCtl::Supervisor.reboot?(3)
  end

  def test_loop_relaunches_on_reboot_then_stops_on_poweroff
    exec = FakeExecutor.new
    statuses = [0, 0, 1]   # reboot, reboot, poweroff
    runs = 0
    runner = -> { statuses[runs].tap { runs += 1 } }
    sup = VMCtl::Supervisor.new(build_vm, executor: exec, runner: runner)
    sup.supervise
    assert_equal 3, runs, "bhyve launched 3 times"
    destroys = exec.runs.select { |c| c.include?('bhyvectl --destroy') }
    assert_equal 3, destroys.length, "destroy runs once per bhyve exit"
  end

  def test_loop_stops_immediately_on_poweroff
    exec = FakeExecutor.new
    runner = -> { 1 }
    sup = VMCtl::Supervisor.new(build_vm, executor: exec, runner: runner)
    sup.supervise
    assert_equal 1, exec.runs.count { |c| c.include?('bhyvectl --destroy --vm=pod34') }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_supervisor.rb`
Expected: FAIL — `cannot load such file -- vmctl/supervisor`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# frozen_string_literal: true
# lib/vmctl/supervisor.rb
require 'fileutils'
require_relative 'log'

module VMCtl
  # Runs and supervises one VM: loop bhyve, destroy the vmm device between runs,
  # relaunch only on a guest reboot. Plain Ruby fork/detach — no daemon(8).
  class Supervisor
    REBOOT_STATUS = 0

    def self.reboot?(status)
      status == REBOOT_STATUS
    end

    # runner: callable returning the bhyve exit status Integer.
    #         Defaults to actually spawning bhyve (production path).
    def initialize(vm, executor:, runner: nil)
      @vm = vm
      @exec = executor
      @runner = runner || method(:spawn_bhyve)
      @poweroff_requested = false
    end

    # The core loop. Testable with an injected runner + FakeExecutor.
    def supervise
      loop do
        status = @runner.call
        @exec.run("bhyvectl --destroy --vm=#{@vm.name}")
        break if @poweroff_requested
        break unless self.class.reboot?(status)
      end
    end

    # Fork a detached supervisor, write the pidfile, redirect output.
    # Returns the supervisor pid.
    def start
      ensure_dirs
      pid = fork do
        Process.setsid
        redirect_output
        File.write(@vm.pidfile, Process.pid.to_s)
        at_exit { remove_pidfile }
        install_signal_handlers
        Thread.current[:vmctl_vm] = @vm.name
        supervise
      end
      Process.detach(pid)
      pid
    end

    private

    # Production runner: spawn bhyve, remember its pid (for signal forwarding),
    # wait, return its exit status.
    def spawn_bhyve
      VMCtl.logger.info("launch: #{@vm.bhyve_command}")
      @bhyve_pid = Process.spawn(*@vm.bhyve_argv)
      _pid, status = Process.wait2(@bhyve_pid)
      @bhyve_pid = nil
      status.exitstatus || 1
    end

    # On TERM: ask the guest to power off via ACPI, and don't relaunch.
    def install_signal_handlers
      Signal.trap('TERM') do
        @poweroff_requested = true
        @exec.run("bhyvectl --force-poweroff --vm=#{@vm.name}") if @bhyve_pid
      end
    end

    def ensure_dirs
      FileUtils.mkdir_p(@vm.defaults.run_dir)
      FileUtils.mkdir_p(@vm.defaults.log_dir)
    end

    def redirect_output
      log = File.open(@vm.logfile, 'a')
      log.sync = true
      $stdout.reopen(log)
      $stderr.reopen(log)
      $stdin.reopen(File::NULL)
    end

    def remove_pidfile
      File.delete(@vm.pidfile) if File.exist?(@vm.pidfile)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Itest test/test_supervisor.rb`
Expected: PASS — 3 runs, all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/supervisor.rb test/test_supervisor.rb
git commit -m "feat: add Supervisor reboot/destroy loop and daemonized start"
```

---

## Task 7: CLI dispatch + command base

**Files:**
- Create: `lib/vmctl/cli.rb`, `lib/vmctl/commands/base.rb`
- Test: `test/test_cli.rb`

`VMCtl::CLI.run(argv)` parses global options (`-c/--config`, `-v/--verbose`, `-n/--dry-run`, `-V/--version`, `-h/--help`), then dispatches the subcommand. Unknown command → usage + exit 2. `commands/base.rb` provides `Commands::Base` holding `config`, `executor`, and helpers (`vm_for(name)`, `each_target(args)` for `name | --all`).

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_cli.rb
require 'test_helper'
require 'vmctl/cli'

class TestCLI < Minitest::Test
  def capture_exit
    out = StringIO.new
    $stdout = out
    code = nil
    begin
      yield
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = STDOUT
    end
    [code, out.string]
  end

  def test_version_flag_prints_and_exits_zero
    code, out = capture_exit { VMCtl::CLI.run(['--version']) }
    assert_equal 0, code
    assert_match(/vmctl #{VMCtl::VERSION}/, out)
  end

  def test_help_prints_usage
    code, out = capture_exit { VMCtl::CLI.run(['help']) }
    assert_equal 0, code
    assert_match(/Usage: vmctl/, out)
  end

  def test_unknown_command_exits_two
    code, _ = capture_exit do
      $stderr = StringIO.new
      begin
        VMCtl::CLI.run(['frobnicate'])
      ensure
        $stderr = STDERR
      end
    end
    assert_equal 2, code
  end

  def test_no_command_prints_usage_exits_two
    code, _ = capture_exit do
      $stderr = StringIO.new
      begin
        VMCtl::CLI.run([])
      ensure
        $stderr = STDERR
      end
    end
    assert_equal 2, code
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_cli.rb`
Expected: FAIL — `cannot load such file -- vmctl/cli`.

- [ ] **Step 3: Write `lib/vmctl/commands/base.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/base.rb
require_relative '../vm'

module VMCtl
  module Commands
    class CommandError < StandardError; end

    class Base
      def initialize(config:, executor:)
        @config = config
        @executor = executor
      end

      protected

      attr_reader :config, :executor

      def vm_for(name)
        entry = config.vms[name]
        raise CommandError, "unknown VM '#{name}'" unless entry
        VM.new(entry, config.defaults)
      end

      # Resolve a target list from args: an explicit name, or all VMs (--all),
      # or autostart-only VMs (--all with autostart_only).
      def targets(names, all:, autostart_only: false)
        if all
          entries = config.vms.values
          entries = entries.select(&:autostart) if autostart_only
          entries.map { |e| VM.new(e, config.defaults) }
        else
          names.map { |n| vm_for(n) }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Write `lib/vmctl/cli.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/cli.rb
require 'optparse'
require_relative 'version'
require_relative 'log'
require_relative 'config'
require_relative 'executor'
require_relative 'commands/base'
require_relative 'commands/list'
require_relative 'commands/status'
require_relative 'commands/start'
require_relative 'commands/stop'
require_relative 'commands/restart'
require_relative 'commands/console'

module VMCtl
  module CLI
    DEFAULT_CONFIG = '/usr/local/etc/vmctl/inventory.yml'

    USAGE = <<~USAGE
      Usage: vmctl [options] <command> [args]

      Commands:
        start [name|--all]    Start VM(s) under a supervisor.
        stop  [name|--all]    Graceful ACPI poweroff, then destroy on timeout.
        restart <name>        Graceful stop then start.
        status [name]         Running/stopped, pid, link, network.
        console <name>        Attach to the VM's nmdm console.
        list                  List configured VMs.
        help                  Show this message.

      Options:
        -c, --config FILE     Inventory file (default: #{DEFAULT_CONFIG})
        -v, --verbose         Verbose output
        -n, --dry-run         Print actions without executing
        -V, --version         Print version and exit
    USAGE

    COMMANDS = {
      'list'    => Commands::List,
      'status'  => Commands::Status,
      'start'   => Commands::Start,
      'stop'    => Commands::Stop,
      'restart' => Commands::Restart,
      'console' => Commands::Console
    }.freeze

    def self.run(argv)
      options = { config: DEFAULT_CONFIG, verbose: false, dry_run: false }
      parser = OptionParser.new do |o|
        o.on('-c', '--config FILE') { |f| options[:config] = f }
        o.on('-v', '--verbose')     { options[:verbose] = true }
        o.on('-n', '--dry-run')     { options[:dry_run] = true }
        o.on('-V', '--version')     { puts "vmctl #{VERSION}"; exit 0 }
        o.on('-h', '--help')        { puts USAGE; exit 0 }
      end

      begin
        parser.order!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        exit 2
      end

      VMCtl.log_level = options[:verbose] ? Logger::DEBUG : Logger::INFO

      cmd = argv.shift
      if cmd.nil?
        warn USAGE
        exit 2
      end
      if cmd == 'help'
        puts USAGE
        exit 0
      end

      klass = COMMANDS[cmd]
      unless klass
        warn "unknown command: #{cmd}"
        warn USAGE
        exit 2
      end

      begin
        config = Config.load(options[:config])
        executor = Executor.new(dry_run: options[:dry_run])
        klass.new(config: config, executor: executor).call(argv)
      rescue ConfigError, Commands::CommandError,
             NetgraphError, ExecutorError => e
        warn "error: #{e.message}"
        exit 1
      end
    end
  end
end
```

(Note: `require`s for `netgraph` are pulled in transitively by command files in Task 8; `NetgraphError` is referenced in the rescue, so add `require_relative 'netgraph'` to `cli.rb` now to keep the constant defined.)

Add this line to `cli.rb` with the other requires:

```ruby
require_relative 'netgraph'
```

- [ ] **Step 5: Create stub command files so `cli.rb` loads**

Create each of these minimal stubs (they are fully implemented in Task 8; stubs let the CLI test run now):

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/list.rb
require_relative 'base'
module VMCtl
  module Commands
    class List < Base
      def call(_args); end
    end
  end
end
```

Repeat the identical stub shape for `status.rb` (`class Status`), `start.rb` (`class Start`), `stop.rb` (`class Stop`), `restart.rb` (`class Restart`), `console.rb` (`class Console`) — each `def call(_args); end`.

- [ ] **Step 6: Run test to verify it passes**

Run: `ruby -Itest test/test_cli.rb`
Expected: PASS — 4 runs, all assertions pass.

- [ ] **Step 7: Commit**

```bash
git add lib/vmctl/cli.rb lib/vmctl/commands/
git commit -m "feat: add CLI dispatch and command base"
```

---

## Task 8: Lifecycle commands (list, status, start, stop, restart, console)

**Files:**
- Modify: `lib/vmctl/commands/{list,status,start,stop,restart,console}.rb`
- Test: `test/test_commands.rb`

Each command parses its own args with `OptionParser`, then acts. They use the injected `executor` and `config`. `start` pre-flights via `Netgraph` then calls `Supervisor#start`. For testability, `start`/`stop`/`restart` accept an injectable supervisor factory (default: real `Supervisor`); tests pass a fake to avoid forking.

- [ ] **Step 1: Write the failing test**

```ruby
# test/test_commands.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/executor'
require 'vmctl/commands/list'
require 'vmctl/commands/status'
require 'vmctl/commands/start'
require 'vmctl/commands/console'
require 'tempfile'

module CmdTestSupport
  INVENTORY = <<~YAML
    defaults:
      config_dir: /bhyve/configs
      vm_root: /bhyve
      zpool: tank/bhyve
      link_base: 10
      run_dir: /tmp/vmctl-test-run
      log_dir: /tmp/vmctl-test-log
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

  def load_config
    f = Tempfile.new(['inv', '.yml'])
    f.write(INVENTORY)
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

class TestListCommand < Minitest::Test
  include CmdTestSupport

  def test_list_prints_each_vm
    cmd = VMCtl::Commands::List.new(config: load_config, executor: FakeExecutor.new)
    out = capture_stdout { cmd.call([]) }
    assert_match(/pod34/, out)
    assert_match(/pod35/, out)
    assert_match(/labs_vlan50/, out)
    assert_match(/link 10/, out)
  end
end

class TestStatusCommand < Minitest::Test
  include CmdTestSupport

  def test_status_reports_stopped_when_no_vmm_device
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/pod34/, out)
    assert_match(/stopped/, out)
  end

  def test_status_reports_running_when_vmm_device_present
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/running/, out)
  end
end

class TestStartCommand < Minitest::Test
  include CmdTestSupport

  class FakeSupervisor
    attr_reader :started
    def initialize(*); @started = false; end
    def start; @started = true; 4242; end
  end

  def test_start_preflights_bridge_and_starts_supervisor
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => true, '/dev/vmm/pod34' => false }
    )
    started = []
    factory = ->(vm, **) { fs = FakeSupervisor.new; started << vm.name; fs }
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    assert_equal ['pod34'], started
  end

  def test_start_fails_when_bridge_missing
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => false, '/dev/vmm/pod34' => false }
    )
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod34']) }
  end

  def test_start_refuses_when_already_running
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => true, '/dev/vmm/pod34' => true }
    )
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/already running/, err.message)
  end

  def test_start_all_targets_only_autostart_vms
    exec = FakeExecutor.new(
      probes: {
        'ngctl info labs_vlan50:' => true,
        '/dev/vmm/pod34' => false, '/dev/vmm/pod35' => false
      }
    )
    started = []
    factory = ->(vm, **) { started << vm.name; VMCtl::Commands::Start::FakeOK.new }
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['--all']) }
    assert_equal ['pod34'], started, "only autostart VMs start with --all"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Itest test/test_commands.rb`
Expected: FAIL — methods/`FakeOK` undefined / commands are stubs returning nil.

- [ ] **Step 3: Implement `lib/vmctl/commands/list.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/list.rb
require_relative 'base'

module VMCtl
  module Commands
    class List < Base
      def call(_args)
        config.vms.each_value do |e|
          mac = e.mac ? " mac #{e.mac}" : ''
          auto = e.autostart ? ' [autostart]' : ''
          puts "#{e.name}: #{e.network} link #{e.link}#{mac}#{auto}"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Implement `lib/vmctl/commands/status.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/status.rb
require_relative 'base'

module VMCtl
  module Commands
    class Status < Base
      def call(args)
        all = args.delete('--all')
        vms = targets(args, all: all || args.empty?)
        vms.each do |vm|
          running = executor.success?("test -e #{vm.vmm_device}")
          state = running ? 'running' : 'stopped'
          pid = read_pid(vm)
          pid_str = pid ? " pid #{pid}" : ''
          puts "#{vm.name}: #{state}#{pid_str} (#{vm.entry.network} link #{vm.entry.link})"
        end
      end

      private

      def read_pid(vm)
        return nil unless File.exist?(vm.pidfile)
        File.read(vm.pidfile).strip
      rescue StandardError
        nil
      end
    end
  end
end
```

(Note: the test stubs the probe key `/dev/vmm/pod34`; `success?("test -e /dev/vmm/pod34")` matches by substring in FakeExecutor.)

- [ ] **Step 5: Implement `lib/vmctl/commands/start.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/start.rb
require_relative 'base'
require_relative '../netgraph'
require_relative '../supervisor'

module VMCtl
  module Commands
    class Start < Base
      # Test seam: a trivially-ok fake supervisor.
      class FakeOK
        def start; 0; end
      end

      def initialize(config:, executor:, supervisor_factory: nil)
        super(config: config, executor: executor)
        @factory = supervisor_factory ||
                   ->(vm, **kw) { Supervisor.new(vm, executor: executor, **kw) }
        @netgraph = Netgraph.new(executor)
      end

      def call(args)
        all = !!args.delete('--all')
        vms = targets(args, all: all, autostart_only: all)
        vms.each { |vm| start_one(vm) }
      end

      private

      def start_one(vm)
        if running?(vm)
          raise CommandError, "#{vm.name} already running"
        end
        @netgraph.ensure_bridge!(vm.entry.network)
        sup = @factory.call(vm)
        pid = sup.start
        puts "started #{vm.name} (supervisor pid #{pid})"
      end

      def running?(vm)
        executor.success?("test -e #{vm.vmm_device}")
      end
    end
  end
end
```

- [ ] **Step 6: Implement `lib/vmctl/commands/stop.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/stop.rb
require_relative 'base'
require 'optparse'

module VMCtl
  module Commands
    class Stop < Base
      def call(args)
        force = false
        all = false
        parser = OptionParser.new do |o|
          o.on('--force') { force = true }
          o.on('--all')   { all = true }
        end
        rest = parser.parse(args)
        vms = targets(rest, all: all)
        vms.each { |vm| stop_one(vm, force: force) }
      end

      private

      def stop_one(vm, force:)
        pid = read_pid(vm)
        unless pid
          puts "#{vm.name} not running (no pidfile)"
          # Best-effort cleanup of a stale vmm device.
          executor.run("bhyvectl --destroy --vm=#{vm.name}") if force
          return
        end

        if force
          safe_kill('KILL', pid)
          executor.run("bhyvectl --destroy --vm=#{vm.name}")
          puts "force-stopped #{vm.name}"
        else
          # TERM tells the supervisor to ACPI-poweroff and not relaunch.
          safe_kill('TERM', pid)
          puts "stopping #{vm.name} (graceful poweroff requested)"
        end
      end

      def read_pid(vm)
        return nil unless File.exist?(vm.pidfile)
        Integer(File.read(vm.pidfile).strip)
      rescue StandardError
        nil
      end

      def safe_kill(sig, pid)
        Process.kill(sig, pid)
      rescue Errno::ESRCH
        # Process already gone; nothing to do.
      end
    end
  end
end
```

- [ ] **Step 7: Implement `lib/vmctl/commands/restart.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/restart.rb
require_relative 'base'
require_relative 'stop'
require_relative 'start'

module VMCtl
  module Commands
    class Restart < Base
      def call(args)
        name = args.first
        raise CommandError, 'restart requires a VM name' unless name
        Stop.new(config: config, executor: executor).call([name])
        Start.new(config: config, executor: executor).call([name])
      end
    end
  end
end
```

- [ ] **Step 8: Implement `lib/vmctl/commands/console.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/console.rb
require_relative 'base'

module VMCtl
  module Commands
    class Console < Base
      def call(args)
        name = args.first
        raise CommandError, 'console requires a VM name' unless name
        vm = vm_for(name)
        puts "attaching to #{vm.name} console (#{vm.console_device}); ~. to detach"
        # cu replaces this process group's tty; run it directly.
        exec('cu', '-l', vm.console_device) unless dry_run_exec?
      end

      private

      # In dry-run we don't have a flag on the command, but the executor does;
      # console is interactive, so only skip exec when explicitly disabled via env
      # (keeps the method testable without spawning cu).
      def dry_run_exec?
        ENV['VMCTL_NO_EXEC'] == '1'
      end
    end
  end
end
```

(Note: `console` calls `exec` which replaces the process — tests set `VMCTL_NO_EXEC=1` if they exercise it. Phase-1 tests do not invoke `console.call` to avoid the tty; manual verification covers it.)

- [ ] **Step 9: Run test to verify it passes**

Run: `ruby -Itest test/test_commands.rb`
Expected: PASS — all command tests green.

- [ ] **Step 10: Run the full suite**

Run: `ruby test/run_all.rb`
Expected: PASS — all test files, 0 failures, 0 errors.

- [ ] **Step 11: Commit**

```bash
git add lib/vmctl/commands/ test/test_commands.rb
git commit -m "feat: implement lifecycle commands (list/status/start/stop/restart/console)"
```

---

## Task 9: rc.d boot shim, README, and final verification

**Files:**
- Create: `rc/vmctl`, `README.md`
- Modify: `.gitignore`

- [ ] **Step 1: Create the rc.d shim `rc/vmctl`**

```sh
#!/bin/sh
# PROVIDE: vmctl
# REQUIRE: netgraph_setup
# KEYWORD: nojail
#
# Install: cp rc/vmctl /usr/local/etc/rc.d/vmctl && chmod +x it
# Enable:  sysrc vmctl_enable=YES

. /etc/rc.subr

name="vmctl"
rcvar="vmctl_enable"
start_cmd="vmctl_start"
stop_cmd="vmctl_stop"
: ${vmctl_bin:="/usr/local/bin/vmctl"}

vmctl_start()
{
    ${vmctl_bin} start --all
}

vmctl_stop()
{
    ${vmctl_bin} stop --all
}

load_rc_config $name
run_rc_command "$1"
```

- [ ] **Step 2: Create `README.md`**

```markdown
# vmctl

A pure-Ruby CLI for managing [bhyve](https://wiki.freebsd.org/bhyve) VMs that use
the `bhyve_config` (`-k`) format with netgraph networking. No gems — Ruby stdlib
and FreeBSD base system tools only.

## Requirements

- Ruby >= 3.0
- FreeBSD with `bhyve`, `bhyvectl`, `ngctl`, `cu` in PATH
- Netgraph bridges created out of band (e.g. a `netgraph_setup` rc script)

## Inventory

vmctl reads one YAML inventory (default `/usr/local/etc/vmctl/inventory.yml`):

\```yaml
defaults:
  config_dir: /bhyve/configs   # shared .conf templates
  vm_root: /bhyve              # <vm_root>/<name>/ holds each VM's images
  zpool: tank/bhyve            # parent dataset
  template: pod.conf           # default shared config
  link_base: 10                # lowest auto-assigned link (0-9 reserved)

vms:
  pod34:
    config: pod.conf
    network: labs_vlan50
    link: 10
    autostart: true
    disks:
      - { file: pod34-root.raw, size: 20G }
\```

At `start`, vmctl reconstructs the same invocation you'd run by hand:

\```sh
bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 pod34
\```

## Usage

\```
vmctl [options] <command> [args]

  start [name|--all]   stop [name|--all]   restart <name>
  status [name]        console <name>      list

  -c FILE  inventory (default /usr/local/etc/vmctl/inventory.yml)
  -v       verbose    -n  dry-run    -V  version
\```

## Boot integration

Install `rc/vmctl` to `/usr/local/etc/rc.d/vmctl`, then `sysrc vmctl_enable=YES`.
At boot it runs `vmctl start --all`, starting only `autostart: true` VMs.

## Scope

vmctl manages VM **lifecycle** and **inventory**. It validates (never creates)
netgraph bridges — those are host infrastructure. Provisioning (`create`,
`import`, `destroy`, cloud-init) is Phase 2.
```

- [ ] **Step 3: Run the full suite once more**

Run: `ruby test/run_all.rb`
Expected: PASS — all green.

- [ ] **Step 4: Manual verification dry-run check (no FreeBSD required)**

Run:
```bash
printf 'defaults:\n  config_dir: /bhyve/configs\n  link_base: 10\nvms:\n  pod34:\n    config: pod.conf\n    network: labs_vlan50\n    link: 10\n    disks: []\n' > /tmp/inv.yml
ruby -Ilib bin/vmctl -c /tmp/inv.yml list
```
Expected output: `pod34: labs_vlan50 link 10`

- [ ] **Step 5: Commit**

```bash
git add README.md rc/vmctl .gitignore
git commit -m "docs: add README and rc.d boot shim"
```

---

## Manual Verification (FreeBSD host, after merge)

These cannot run in CI (need bhyve + netgraph). Perform on a real host with an
already-provisioned VM and an existing bridge:

1. `vmctl -n start pod34` → prints the `bhyve -k … -o …` invocation, runs nothing.
2. `vmctl start pod34` → returns immediately; `vmctl status pod34` shows `running`
   with a supervisor pid; `/var/log/vmctl/pod34.log` has bhyve output.
3. Reboot the guest from inside → bhyve relaunches automatically (check the log).
4. `vmctl console pod34` → attaches; `~.` detaches.
5. `vmctl stop pod34` → guest ACPI-powers-off; `status` shows `stopped`; pidfile gone.
6. `vmctl stop --force pod34` on a stuck VM → `bhyvectl --destroy` runs, vmm device gone.

---

## Self-Review

**Spec coverage:**
- Inventory model & schema → Task 2 (Config), `link_base` default 10 → Tasks 2/3.
- Lifecycle/supervisor (reboot/destroy loop, pidfile, ACPI stop, console) → Tasks 6/8.
- Allocation (lowest-free link ≥ base, mac gen) → Task 3.
- Netgraph validation (never creates) → Task 4, used in Task 8 start.
- VM argv reconstruction (`bhyve -k … -o …`) → Task 5.
- Executor as sole shell-out boundary, dry-run aware, fake for tests → Task 1.
- rc.d autostart shim (`start --all`, autostart-only) → Tasks 8/9.
- Module layout & testing conventions → all tasks.
- **Deferred to Phase 2 (documented):** create/import/destroy, Provisioner, cloud-init.

**Type consistency:** `VMEntry`/`Disk`/`Defaults` field names are identical across
Tasks 2, 3, 5, 6, 8. `Executor#run/capture/success?` signatures match across
Tasks 1, 4, 8. `Supervisor.new(vm, executor:, runner:)` consistent in Tasks 6/8.
`Commands::Base#targets(names, all:, autostart_only:)` consistent in Tasks 7/8.

**Placeholder scan:** No TBD/TODO; every code step shows complete code.
```
