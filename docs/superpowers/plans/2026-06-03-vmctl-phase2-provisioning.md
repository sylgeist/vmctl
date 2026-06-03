# vmctl Phase 2 — Provisioning (create / import / destroy + cloud-init) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add VM provisioning to vmctl — `create` (allocate IDs + lay down a per-VM ZFS dataset, raw image files, optional cloud-init seed ISO), `import` (adopt a `zfs recv`'d VM's existing disks), and `destroy` (remove a VM, optionally purging its dataset).

**Architecture:** Two new domain objects (`Provisioner`, `CloudInit`) drive `zfs`/`truncate`/`cp`/`makefs` through the existing `Executor`; a small `Sizes` utility handles size parse/format. Three thin command handlers orchestrate `Allocator` + `Netgraph` + `Provisioner` + `CloudInit` + `Config`. Templates stay opaque (the inventory `disks:` list is the sole source of truth). Builds entirely on Phase 1; writes valid Phase-1 inventory entries.

**Tech Stack:** Ruby (stdlib only — no gems), `Open3`, `YAML`, minitest. FreeBSD base tools: `zfs`, `truncate`, `cp`, `makefs`.

**Spec:** `docs/superpowers/specs/2026-06-03-vmctl-phase2-provisioning-design.md`.

**Conventions (unchanged from Phase 1):** `VMCtl` namespace; `# frozen_string_literal: true` + path-comment headers; `Executor` is the sole shell-out boundary; commands thin; tests via `ruby -Ilib -Itest test/run_all.rb` (the `-Ilib -Itest` flags are REQUIRED). Custom error types rescued by the CLI: `CommandError`, `NetgraphError`, `ConfigError`, `ExecutorError`, `OptionParser::ParseError`. Git commits in this repo require the sandbox disabled — implementers should NOT commit; the controller commits.

**Existing signatures this plan depends on (verified against `main`):**
- `Config.load(path)`, `Config#initialize(raw, path=nil)`, `Config#save(path)`, `attr_reader :defaults, :vms, :path`.
- `Defaults` struct (keyword_init): `config_dir, vm_root, zpool, template, link_base, run_dir, log_dir`.
- `VMEntry` struct (keyword_init): `name, config, network, link, mac, autostart, disks, cloud_init`.
- `Disk` struct (keyword_init): `file, size, from`.
- `VM.new(entry, defaults)` → `name, dir, template_path, disk_paths, vmm_device, running?(executor)`.
- `Allocator.new(config)` → `next_link, link_taken?(n), name_taken?(name), generate_mac(name)`.
- `Netgraph.new(executor)` → `ensure_bridge!(name)` (raises `NetgraphError`).
- `Executor` → `run(cmd)` (no-op+logs in dry-run), `capture(cmd)`, `success?(cmd)`, `dry_run?`.
- `Commands::Base` → `protected config, executor, vm_for(name), targets(...)`; `Commands::CommandError`.
- `FakeExecutor.new(captures:, probes:, dry_run:)` records `runs`/`captures`.

---

## File Structure

```
lib/vmctl/
  sizes.rb                  # NEW: VMCtl::Sizes.parse(str)->bytes, .human(bytes)->str
  provisioner.rb            # NEW: zfs create; raw disk create (truncate) / clone (cp) / grow
  cloudinit.rb              # NEW: meta-data generation + seed-dir + makefs cidata ISO
  config.rb                 # MODIFY: + image_dir/root_size/root_from defaults; add_vm/remove_vm
  cli.rb                    # MODIFY: register create/import/destroy; usage text
  commands/
    create.rb               # NEW (replaces no-op none): orchestrate provision + register
    import.rb               # NEW
    destroy.rb              # NEW
test/
  test_sizes.rb test_provisioner.rb test_cloudinit.rb
  test_config.rb            # MODIFY: add cases for new defaults + add_vm/remove_vm
  test_create_command.rb test_import_command.rb test_destroy_command.rb
README.md                   # MODIFY: document create/import/destroy
```

---

## Task 1: `Sizes` utility (parse + human-readable)

**Files:** Create `lib/vmctl/sizes.rb`, `test/test_sizes.rb`

`VMCtl::Sizes.parse("20G")` → bytes (1024-based, matching `truncate`). `VMCtl::Sizes.human(bytes)` → the largest exact unit string, else the raw byte count.

- [ ] **Step 1: Write the failing test** — `test/test_sizes.rb`:

```ruby
# frozen_string_literal: true
# test/test_sizes.rb
require 'test_helper'
require 'vmctl/sizes'

class TestSizes < Minitest::Test
  def test_parse_units
    assert_equal 1024, VMCtl::Sizes.parse('1K')
    assert_equal 20 * 1024**3, VMCtl::Sizes.parse('20G')
    assert_equal 100 * 1024**4, VMCtl::Sizes.parse('100T')
    assert_equal 512 * 1024**2, VMCtl::Sizes.parse('512M')
  end

  def test_parse_plain_bytes
    assert_equal 1048576, VMCtl::Sizes.parse('1048576')
  end

  def test_parse_is_case_insensitive
    assert_equal 20 * 1024**3, VMCtl::Sizes.parse('20g')
  end

  def test_parse_rejects_garbage
    assert_raises(ArgumentError) { VMCtl::Sizes.parse('notasize') }
    assert_raises(ArgumentError) { VMCtl::Sizes.parse('') }
  end

  def test_human_exact_units
    assert_equal '20G', VMCtl::Sizes.human(20 * 1024**3)
    assert_equal '512M', VMCtl::Sizes.human(512 * 1024**2)
    assert_equal '1K', VMCtl::Sizes.human(1024)
  end

  def test_human_non_divisible_falls_back_to_bytes
    assert_equal '1000', VMCtl::Sizes.human(1000)
    assert_equal '0', VMCtl::Sizes.human(0)
  end

  def test_round_trip
    assert_equal 20 * 1024**3, VMCtl::Sizes.parse(VMCtl::Sizes.human(20 * 1024**3))
  end
end
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `ruby -Ilib -Itest test/test_sizes.rb`
Expected: FAIL — `cannot load such file -- vmctl/sizes`.

- [ ] **Step 3: Implement `lib/vmctl/sizes.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/sizes.rb
module VMCtl
  # Parse/format disk sizes using 1024-based units (matching truncate(1)).
  module Sizes
    UNITS = { 'K' => 1024, 'M' => 1024**2, 'G' => 1024**3, 'T' => 1024**4 }.freeze
    ORDERED = [['T', 1024**4], ['G', 1024**3], ['M', 1024**2], ['K', 1024]].freeze

    def self.parse(str)
      m = /\A(\d+)([KMGT]?)\z/i.match(str.to_s)
      raise ArgumentError, "invalid size: #{str.inspect}" unless m
      n = m[1].to_i
      suffix = m[2].upcase
      suffix.empty? ? n : n * UNITS.fetch(suffix)
    end

    def self.human(bytes)
      return '0' if bytes.zero?
      ORDERED.each do |suffix, factor|
        return "#{bytes / factor}#{suffix}" if (bytes % factor).zero?
      end
      bytes.to_s
    end
  end
end
```

- [ ] **Step 4: Run it, confirm pass**

Run: `ruby -Ilib -Itest test/test_sizes.rb`
Expected: PASS — 7 runs, 0 failures.

- [ ] **Step 5: Full suite + commit-prep**

Run: `ruby -Ilib -Itest test/run_all.rb` → all green. (Do NOT commit; controller commits.)

---

## Task 2: Config extensions (new defaults + add_vm/remove_vm)

**Files:** Modify `lib/vmctl/config.rb`, `test/test_config.rb`

Add `image_dir`/`root_size`/`root_from` to the `Defaults` struct, `DEFAULTS`, and `parse_defaults`. Add `Config#add_vm(entry)` and `Config#remove_vm(name)`.

- [ ] **Step 1: Write failing tests** — append to `test/test_config.rb` inside `class TestConfig` (before the final `end`):

```ruby
  def test_new_provisioning_defaults_fill_in
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/bhyve/images', cfg.defaults.image_dir
    assert_equal '20G', cfg.defaults.root_size
    assert_nil cfg.defaults.root_from
    f.close
  end

  def test_new_defaults_are_overridable_and_round_trip
    yaml = "defaults:\n  image_dir: /tank/img\n  root_size: 40G\n  root_from: base.raw\nvms: {}\n"
    f = write_inventory(yaml)
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/tank/img', cfg.defaults.image_dir
    assert_equal '40G', cfg.defaults.root_size
    assert_equal 'base.raw', cfg.defaults.root_from
    out = File.join(Dir.mktmpdir, 'out.yml')
    cfg.save(out)
    reloaded = VMCtl::Config.load(out)
    assert_equal '/tank/img', reloaded.defaults.image_dir
    assert_equal '40G', reloaded.defaults.root_size
    assert_equal 'base.raw', reloaded.defaults.root_from
    f.close
  end

  def test_add_and_remove_vm
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    entry = VMCtl::VMEntry.new(
      name: 'pod99', config: 'pod.conf', network: 'labs_vlan50', link: 10,
      mac: nil, autostart: false,
      disks: [VMCtl::Disk.new(file: 'pod99-root.raw', size: '20G', from: nil)],
      cloud_init: nil
    )
    cfg.add_vm(entry)
    assert cfg.vms.key?('pod99')
    cfg.remove_vm('pod99')
    refute cfg.vms.key?('pod99')
    f.close
  end
```

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_config.rb`
Expected: FAIL — `NoMethodError` for `image_dir` / `add_vm`.

- [ ] **Step 3: Implement** — three edits in `lib/vmctl/config.rb`.

(a) Extend the `Defaults` struct:
```ruby
  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from,
    keyword_init: true
  )
```

(b) Add the new keys to `DEFAULTS`:
```ruby
    DEFAULTS = {
      'config_dir' => '/bhyve/configs',
      'vm_root'    => '/bhyve',
      'zpool'      => 'tank/bhyve',
      'template'   => 'pod.conf',
      'link_base'  => 10,
      'run_dir'    => '/var/run/vmctl',
      'log_dir'    => '/var/log/vmctl',
      'image_dir'  => '/bhyve/images',
      'root_size'  => '20G',
      'root_from'  => nil
    }.freeze
```

(c) Populate them in `parse_defaults` (add the three lines to the `Defaults.new(...)` call):
```ruby
      Defaults.new(
        config_dir: merged['config_dir'],
        vm_root:    merged['vm_root'],
        zpool:      merged['zpool'],
        template:   merged['template'],
        link_base:  parse_link_base(merged['link_base']),
        run_dir:    merged['run_dir'],
        log_dir:    merged['log_dir'],
        image_dir:  merged['image_dir'],
        root_size:  merged['root_size'],
        root_from:  merged['root_from']
      )
```

(d) Add the two public methods to the `Config` class (place them right after the `save` method):
```ruby
    def add_vm(entry)
      @vms[entry.name] = entry
    end

    def remove_vm(name)
      @vms.delete(name)
    end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_config.rb` → all green (existing + 3 new).
Run: `ruby -Ilib -Itest test/run_all.rb` → all green.

(`to_h` already serializes all `Defaults` members via `@defaults.to_h.transform_keys(&:to_s)`, so the new keys round-trip with no change to `to_h`.)

- [ ] **Step 5: Commit-prep** — leave uncommitted; controller commits.

---

## Task 3: `Provisioner` (dataset + raw disk create/clone/grow)

**Files:** Create `lib/vmctl/provisioner.rb`, `test/test_provisioner.rb`

`Provisioner.new(executor, defaults)`. Methods: `create_dataset(vm)`, `create_disk(path, size, from:)`, `image_path(from)`. Blank disk → `truncate`; golden → `cp` then `truncate` only if the requested size is larger than the source image (never shrinks; the create command validates "not smaller" beforehand). Uses `Sizes.parse` + `File.size` for the grow check.

- [ ] **Step 1: Write the failing test** — `test/test_provisioner.rb`:

```ruby
# frozen_string_literal: true
# test/test_provisioner.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/provisioner'
require 'tmpdir'

class TestProvisioner < Minitest::Test
  def defaults(image_dir: '/bhyve/images')
    VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10, run_dir: '/var/run/vmctl',
      log_dir: '/var/log/vmctl', image_dir: image_dir, root_size: '20G', root_from: nil
    )
  end

  def vm
    entry = VMCtl::VMEntry.new(name: 'pod35', config: 'pod.conf', network: 'n',
                               link: 12, mac: nil, autostart: false, disks: [], cloud_init: nil)
    VMCtl::VM.new(entry, defaults)
  end

  def test_create_dataset
    exec = FakeExecutor.new
    VMCtl::Provisioner.new(exec, defaults).create_dataset(vm)
    assert_includes exec.runs, 'zfs create tank/bhyve/pod35'
  end

  def test_create_blank_disk_uses_truncate
    exec = FakeExecutor.new
    VMCtl::Provisioner.new(exec, defaults).create_disk('/bhyve/pod35/pod35-zfs.raw', '100G', from: nil)
    assert_includes exec.runs, 'truncate -s 100G /bhyve/pod35/pod35-zfs.raw'
  end

  def test_image_path_resolves_relative_to_image_dir
    p = VMCtl::Provisioner.new(FakeExecutor.new, defaults(image_dir: '/img'))
    assert_equal '/img/base.raw', p.image_path('base.raw')
    assert_equal '/abs/base.raw', p.image_path('/abs/base.raw')
    assert_nil p.image_path(nil)
  end

  def test_clone_grows_when_requested_larger
    dir = Dir.mktmpdir
    img = File.join(dir, 'base.raw')
    File.write(img, 'x' * 1024) # 1K source
    exec = FakeExecutor.new
    p = VMCtl::Provisioner.new(exec, defaults(image_dir: dir))
    p.create_disk('/bhyve/pod35/pod35-root.raw', '1M', from: 'base.raw')
    assert_includes exec.runs, "cp #{img} /bhyve/pod35/pod35-root.raw"
    assert_includes exec.runs, 'truncate -s 1M /bhyve/pod35/pod35-root.raw'
  end

  def test_clone_skips_truncate_when_size_equals_source
    dir = Dir.mktmpdir
    img = File.join(dir, 'base.raw')
    File.write(img, 'x' * 1024) # exactly 1K
    exec = FakeExecutor.new
    p = VMCtl::Provisioner.new(exec, defaults(image_dir: dir))
    p.create_disk('/bhyve/pod35/pod35-root.raw', '1K', from: 'base.raw')
    assert_includes exec.runs, "cp #{img} /bhyve/pod35/pod35-root.raw"
    refute(exec.runs.any? { |c| c.start_with?('truncate') }, 'no grow when size == source')
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_provisioner.rb`
Expected: FAIL — `cannot load such file -- vmctl/provisioner`.

- [ ] **Step 3: Implement `lib/vmctl/provisioner.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/provisioner.rb
require_relative 'sizes'

module VMCtl
  # Lays down a VM's ZFS dataset and raw disk image files. The create command
  # validates inputs (image exists, requested size not smaller than a clone
  # source) before calling here, so this stays mechanical.
  class Provisioner
    def initialize(executor, defaults)
      @exec = executor
      @defaults = defaults
    end

    def create_dataset(vm)
      @exec.run("zfs create #{@defaults.zpool}/#{vm.name}")
    end

    # path: absolute target raw file. size: human size string. from: bare image
    # name (resolved via image_dir) or nil for a blank sparse file.
    def create_disk(path, size, from: nil)
      if from.nil?
        @exec.run("truncate -s #{size} #{path}")
        return
      end
      image = image_path(from)
      @exec.run("cp #{image} #{path}")
      grow_if_needed(path, size, image)
    end

    def image_path(from)
      return nil if from.nil?
      return from if from.start_with?('/')
      File.join(@defaults.image_dir, from)
    end

    private

    def grow_if_needed(path, size, image)
      return unless Sizes.parse(size) > File.size(image)
      @exec.run("truncate -s #{size} #{path}")
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_provisioner.rb` → 5 runs, 0 failures.
Run: `ruby -Ilib -Itest test/run_all.rb` → all green.

- [ ] **Step 5: Commit-prep** — leave uncommitted.

---

## Task 4: `CloudInit` (meta-data + seed ISO)

**Files:** Create `lib/vmctl/cloudinit.rb`, `test/test_cloudinit.rb`

`CloudInit.new(executor)`. `meta_data_for(name)` (pure). `populate_seed(seeddir, vm, user_data_path)` writes `meta-data` + a verbatim `user-data` into `seeddir` (testable directly). `build_seed(vm, user_data_path)` assembles a temp seed dir and runs `makefs` to produce `<vm.dir>/<name>-seed.iso`.

- [ ] **Step 1: Write the failing test** — `test/test_cloudinit.rb`:

```ruby
# frozen_string_literal: true
# test/test_cloudinit.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/cloudinit'
require 'tmpdir'

class TestCloudInit < Minitest::Test
  def vm(dir: '/bhyve')
    defaults = VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: dir, zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10, run_dir: '/var/run/vmctl',
      log_dir: '/var/log/vmctl', image_dir: '/bhyve/images', root_size: '20G', root_from: nil
    )
    entry = VMCtl::VMEntry.new(name: 'pod35', config: 'pod.conf', network: 'n',
                               link: 12, mac: nil, autostart: false, disks: [], cloud_init: nil)
    VMCtl::VM.new(entry, defaults)
  end

  def test_meta_data_has_instance_id_and_hostname
    md = VMCtl::CloudInit.new(FakeExecutor.new).meta_data_for('pod35')
    assert_match(/instance-id:\s*pod35/, md)
    assert_match(/local-hostname:\s*pod35/, md)
  end

  def test_populate_seed_writes_meta_and_user_data
    seeddir = Dir.mktmpdir
    ud = File.join(Dir.mktmpdir, 'ud.yml')
    File.write(ud, "#cloud-config\nusers: []\n")
    VMCtl::CloudInit.new(FakeExecutor.new).populate_seed(seeddir, vm, ud)
    assert_match(/instance-id:\s*pod35/, File.read(File.join(seeddir, 'meta-data')))
    assert_equal "#cloud-config\nusers: []\n", File.read(File.join(seeddir, 'user-data'))
  end

  def test_build_seed_runs_makefs_to_vm_dir
    vmdir = Dir.mktmpdir
    v = vm(dir: vmdir) # vm.dir == <vmdir>/pod35
    FileUtils.mkdir_p(v.dir)
    ud = File.join(Dir.mktmpdir, 'ud.yml')
    File.write(ud, "#cloud-config\n")
    exec = FakeExecutor.new
    iso = VMCtl::CloudInit.new(exec).build_seed(v, ud)
    expected_iso = File.join(v.dir, 'pod35-seed.iso')
    assert_equal expected_iso, iso
    cmd = exec.runs.find { |c| c.start_with?('makefs') }
    refute_nil cmd, 'makefs must run'
    assert_match(/makefs -t cd9660 -o rockridge,label=cidata #{Regexp.escape(expected_iso)} /, cmd)
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_cloudinit.rb`
Expected: FAIL — `cannot load such file -- vmctl/cloudinit`.

- [ ] **Step 3: Implement `lib/vmctl/cloudinit.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/cloudinit.rb
require 'tmpdir'
require 'fileutils'

module VMCtl
  # Builds a NoCloud cloud-init seed ISO: generated meta-data + the operator's
  # verbatim user-data, packed with makefs as an ISO9660 volume labelled cidata.
  class CloudInit
    def initialize(executor)
      @exec = executor
    end

    def meta_data_for(name)
      "instance-id: #{name}\nlocal-hostname: #{name}\n"
    end

    def populate_seed(seeddir, vm, user_data_path)
      File.write(File.join(seeddir, 'meta-data'), meta_data_for(vm.name))
      FileUtils.cp(user_data_path, File.join(seeddir, 'user-data'))
    end

    # Returns the ISO path (<vm.dir>/<name>-seed.iso).
    def build_seed(vm, user_data_path)
      iso = File.join(vm.dir, "#{vm.name}-seed.iso")
      Dir.mktmpdir('vmctl-seed') do |seeddir|
        populate_seed(seeddir, vm, user_data_path)
        @exec.run("makefs -t cd9660 -o rockridge,label=cidata #{iso} #{seeddir}")
      end
      iso
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_cloudinit.rb` → 3 runs, 0 failures.
Run: `ruby -Ilib -Itest test/run_all.rb` → all green.

- [ ] **Step 5: Commit-prep** — leave uncommitted.

---

## Task 5: `create` command

**Files:** Create `lib/vmctl/commands/create.rb`, `test/test_create_command.rb`

Orchestrates allocate → build entry → validate → provision → cloud-init → register → optional start. Validation runs even in dry-run (read-only); only mutations (`Provisioner`/`CloudInit` shell-outs via `Executor`, and `Config#save`) are suppressed by dry-run — the `Executor` no-ops + logs each command, and `save` is guarded explicitly.

- [ ] **Step 1: Write the failing test** — `test/test_create_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_create_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/create'
require 'tmpdir'
require 'tempfile'

class TestCreateCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @config_dir = File.join(@dir, 'configs'); FileUtils.mkdir_p(@config_dir)
    File.write(File.join(@config_dir, 'pod.conf'), "cpus=2\n")
    @image_dir = File.join(@dir, 'images'); FileUtils.mkdir_p(@image_dir)
    File.write(File.join(@image_dir, 'base.raw'), 'x' * 1024)
    @vm_root = File.join(@dir, 'vms'); FileUtils.mkdir_p(@vm_root)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        config_dir: #{@config_dir}
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        template: pod.conf
        link_base: 10
        image_dir: #{@image_dir}
        root_size: 1M
        root_from: base.raw
      vms: {}
    YAML
  end

  def load_config
    VMCtl::Config.load(@inv)
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def bridge_ok(extra = {})
    FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => true }.merge(extra))
  end

  def test_create_allocates_provisions_and_registers
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    # provisioned: dataset + root disk (cloned from base.raw, grown 1K->1M)
    assert_includes exec.runs, 'zfs create tank/bhyve/pod35'
    assert(exec.runs.any? { |c| c.include?('cp ') && c.include?('pod35-root.raw') })
    # registered in the on-disk inventory with an allocated link
    reloaded = VMCtl::Config.load(@inv)
    entry = reloaded.vms.fetch('pod35')
    assert_equal 'labs_vlan50', entry.network
    assert_equal 10, entry.link
    assert_equal 'pod35-root.raw', entry.disks.first.file
  end

  def test_create_requires_network
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod35']) }
  end

  def test_create_rejects_duplicate_name
    exec = bridge_ok
    VMCtl::Commands::Create.new(config: load_config, executor: exec).call(['pod35', '--network', 'labs_vlan50'])
    err = assert_raises(VMCtl::Commands::CommandError) do
      VMCtl::Commands::Create.new(config: load_config, executor: exec).call(['pod35', '--network', 'labs_vlan50'])
    end
    assert_match(/exists/, err.message)
  end

  def test_create_fails_when_bridge_missing
    exec = FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => false })
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod35', '--network', 'labs_vlan50']) }
  end

  def test_create_extra_disk_flag
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--disk', 'zfs:5M']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    files = entry.disks.map(&:file)
    assert_includes files, 'pod35-root.raw'
    assert_includes files, 'pod35-zfs.raw'
    assert(exec.runs.any? { |c| c == 'truncate -s 5M ' + File.join(@vm_root, 'pod35', 'pod35-zfs.raw') })
  end

  def test_create_mac_generate
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--mac', 'generate']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, entry.mac)
  end

  def test_create_cloud_init_records_field_and_builds_seed
    ud = File.join(@dir, 'ud.yml'); File.write(ud, "#cloud-config\n")
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--cloud-init', ud]) }
    assert(exec.runs.any? { |c| c.start_with?('makefs ') })
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_equal 'pod35-user-data.yml', entry.cloud_init['user_data']
  end

  def test_dry_run_writes_nothing
    exec = FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => true }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    assert_equal before, File.read(@inv), 'dry-run must not change the inventory file'
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_create_command.rb`
Expected: FAIL — `cannot load such file -- vmctl/commands/create`.

- [ ] **Step 3: Implement `lib/vmctl/commands/create.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/create.rb
require 'optparse'
require_relative 'base'
require_relative '../allocator'
require_relative '../netgraph'
require_relative '../provisioner'
require_relative '../cloudinit'
require_relative '../sizes'
require_relative 'start'

module VMCtl
  module Commands
    class Create < Base
      def call(args)
        opts = parse(args)
        name = opts[:name]
        raise CommandError, 'create requires a VM name' unless name
        raise CommandError, "VM '#{name}' already exists" if config.vms.key?(name)
        raise CommandError, '--network is required' unless opts[:network]

        entry = build_entry(name, opts)
        vm = VM.new(entry, config.defaults)
        provisioner = Provisioner.new(executor, config.defaults)
        validate!(vm, entry, opts, provisioner)

        provision(vm, entry, provisioner)
        cloud_init(vm, entry, opts[:cloud_init]) if opts[:cloud_init]

        config.add_vm(entry)
        config.save(config.path) unless executor.dry_run?
        puts "created #{name} (link #{entry.link})"

        Start.new(config: config, executor: executor).call([name]) if opts[:start]
      end

      private

      def parse(args)
        o = { disks: [] }
        parser = OptionParser.new do |p|
          p.on('--network NET') { |v| o[:network] = v }
          p.on('--config TMPL') { |v| o[:config] = v }
          p.on('--mac MAC')     { |v| o[:mac] = v }
          p.on('--root-size SIZE') { |v| o[:root_size] = v }
          p.on('--root-from IMG')  { |v| o[:root_from] = v }
          p.on('--disk SPEC')   { |v| o[:disks] << v }
          p.on('--cloud-init FILE') { |v| o[:cloud_init] = v }
          p.on('--autostart')   { o[:autostart] = true }
          p.on('--start')       { o[:start] = true }
        end
        rest = parser.parse(args)
        o[:name] = rest.shift
        o
      end

      def build_entry(name, opts)
        d = config.defaults
        disks = [Disk.new(
          file: "#{name}-root.raw",
          size: opts[:root_size] || d.root_size,
          from: opts.key?(:root_from) ? opts[:root_from] : d.root_from
        )]
        opts[:disks].each { |spec| disks << parse_disk(name, spec) }
        VMEntry.new(
          name: name,
          config: opts[:config] || d.template,
          network: opts[:network],
          link: Allocator.new(config).next_link,
          mac: resolve_mac(name, opts[:mac]),
          autostart: !!opts[:autostart],
          disks: disks,
          cloud_init: nil
        )
      end

      # SPEC = "<suffix>:<size>[:from <image>]" — supports "zfs:100G" and
      # "data:50G:from gold.raw".
      def parse_disk(name, spec)
        body, from = spec.split(':from ', 2)
        suffix, size = body.split(':', 2)
        raise CommandError, "invalid --disk #{spec.inspect}" unless suffix && size
        Disk.new(file: "#{name}-#{suffix}.raw", size: size, from: from)
      end

      def resolve_mac(name, mac)
        return nil if mac.nil?
        return Allocator.new(config).generate_mac(name) if mac == 'generate'
        mac
      end

      def validate!(vm, entry, opts, provisioner)
        Netgraph.new(executor).ensure_bridge!(entry.network)
        raise CommandError, "template not found: #{vm.template_path}" unless File.exist?(vm.template_path)
        raise CommandError, "dataset dir already exists: #{vm.dir}" if File.exist?(vm.dir)
        entry.disks.each do |disk|
          next unless disk.from
          image = provisioner.image_path(disk.from)
          raise CommandError, "image not found: #{image}" unless File.exist?(image)
          if Sizes.parse(disk.size) < File.size(image)
            raise CommandError, "disk #{disk.file} size #{disk.size} is smaller than image #{disk.from}"
          end
        end
        if opts[:cloud_init] && !File.exist?(opts[:cloud_init])
          raise CommandError, "cloud-init file not found: #{opts[:cloud_init]}"
        end
      end

      def provision(vm, entry, provisioner)
        provisioner.create_dataset(vm)
        entry.disks.each do |disk|
          provisioner.create_disk(File.join(vm.dir, disk.file), disk.size, from: disk.from)
        end
      end

      def cloud_init(vm, entry, user_data)
        CloudInit.new(executor).build_seed(vm, user_data)
        dest = File.join(vm.dir, "#{vm.name}-user-data.yml")
        executor.run("cp #{user_data} #{dest}")
        entry.cloud_init = { 'user_data' => "#{vm.name}-user-data.yml" }
      end
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_create_command.rb` → all green.
Run: `ruby -Ilib -Itest test/run_all.rb` → all green.

- [ ] **Step 5: Commit-prep** — leave uncommitted.

---

## Task 6: `import` command

**Files:** Create `lib/vmctl/commands/import.rb`, `test/test_import_command.rb`

Adopt an existing VM's disks: allocate a fresh link, scan `<vm_root>/<name>/*.raw`, build the `disks` list with on-disk sizes, register. Does not provision.

- [ ] **Step 1: Write the failing test** — `test/test_import_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_import_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/import'
require 'tmpdir'

class TestImportCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @vm_root = File.join(@dir, 'vms'); FileUtils.mkdir_p(@vm_root)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        template: pod.conf
        link_base: 10
      vms:
        existing:
          config: pod.conf
          network: labs_vlan50
          link: 10
          disks: []
    YAML
  end

  def make_disks(name, *files_with_bytes)
    d = File.join(@vm_root, name); FileUtils.mkdir_p(d)
    files_with_bytes.each { |f, n| File.write(File.join(d, f), 'x' * n) }
  end

  def load_config; VMCtl::Config.load(@inv); end
  def capture_stdout; out = StringIO.new; $stdout = out; yield; out.string; ensure; $stdout = STDOUT; end

  def test_import_scans_disks_and_allocates_fresh_link
    make_disks('pod40', ['pod40-root.raw', 1024], ['pod40-zfs.raw', 2048])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    capture_stdout { cmd.call(['pod40', '--network', 'labs_vlan50']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod40')
    assert_equal 11, entry.link, 'fresh link allocated (10 is taken)'
    assert_equal 'labs_vlan50', entry.network
    assert_equal %w[pod40-root.raw pod40-zfs.raw], entry.disks.map(&:file).sort
    assert(entry.disks.all? { |d| d.from.nil? })
    assert_equal '1K', entry.disks.find { |d| d.file == 'pod40-root.raw' }.size
  end

  def test_import_requires_network
    make_disks('pod40', ['pod40-root.raw', 1024])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod40']) }
  end

  def test_import_rejects_existing_name
    make_disks('existing', ['existing-root.raw', 1024])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['existing', '--network', 'labs_vlan50']) }
  end

  def test_import_fails_when_dataset_dir_missing
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', '--network', 'labs_vlan50']) }
    assert_match(/not found/, err.message)
  end

  def test_import_fails_when_no_raw_images
    FileUtils.mkdir_p(File.join(@vm_root, 'empty'))
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['empty', '--network', 'labs_vlan50']) }
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_import_command.rb`
Expected: FAIL — `cannot load such file -- vmctl/commands/import`.

- [ ] **Step 3: Implement `lib/vmctl/commands/import.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/import.rb
require 'optparse'
require_relative 'base'
require_relative '../allocator'
require_relative '../sizes'

module VMCtl
  module Commands
    class Import < Base
      def call(args)
        opts = parse(args)
        name = opts[:name]
        raise CommandError, 'import requires a VM name' unless name
        raise CommandError, "VM '#{name}' already exists" if config.vms.key?(name)
        raise CommandError, '--network is required' unless opts[:network]

        dir = File.join(config.defaults.vm_root, name)
        raise CommandError, "dataset dir not found: #{dir}" unless File.directory?(dir)
        raws = Dir.glob(File.join(dir, '*.raw')).sort
        raise CommandError, "no .raw images found in #{dir}" if raws.empty?

        entry = VMEntry.new(
          name: name,
          config: opts[:config] || config.defaults.template,
          network: opts[:network],
          link: Allocator.new(config).next_link,
          mac: opts[:mac],
          autostart: false,
          disks: raws.map { |p| Disk.new(file: File.basename(p), size: Sizes.human(File.size(p)), from: nil) },
          cloud_init: nil
        )
        config.add_vm(entry)
        config.save(config.path) unless executor.dry_run?
        puts "imported #{name} (link #{entry.link}, #{entry.disks.length} disk(s))"
      end

      private

      def parse(args)
        o = {}
        parser = OptionParser.new do |p|
          p.on('--network NET') { |v| o[:network] = v }
          p.on('--config TMPL') { |v| o[:config] = v }
          p.on('--mac MAC')     { |v| o[:mac] = v }
        end
        rest = parser.parse(args)
        o[:name] = rest.shift
        o
      end
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_import_command.rb` → all green.
Run: `ruby -Ilib -Itest test/run_all.rb` → all green.

- [ ] **Step 5: Commit-prep** — leave uncommitted.

---

## Task 7: `destroy` command

**Files:** Create `lib/vmctl/commands/destroy.rb`, `test/test_destroy_command.rb`

Refuse if running; remove from inventory; `--purge` also `zfs destroy`s the dataset; confirm unless `--yes`.

- [ ] **Step 1: Write the failing test** — `test/test_destroy_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_destroy_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/destroy'
require 'tmpdir'

class TestDestroyCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        vm_root: #{@dir}
        zpool: tank/bhyve
        link_base: 10
      vms:
        pod35:
          config: pod.conf
          network: labs_vlan50
          link: 10
          disks: [{ file: pod35-root.raw, size: 20G }]
    YAML
  end

  def load_config; VMCtl::Config.load(@inv); end
  def capture_stdout; out = StringIO.new; $stdout = out; yield; out.string; ensure; $stdout = STDOUT; end

  def stopped_exec(extra = {})
    FakeExecutor.new(probes: { '/dev/vmm/pod35' => false }.merge(extra))
  end

  def test_destroy_removes_from_inventory
    exec = stopped_exec
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--yes']) }
    refute VMCtl::Config.load(@inv).vms.key?('pod35')
    refute(exec.runs.any? { |c| c.start_with?('zfs destroy') }, 'no purge without --purge')
  end

  def test_destroy_purge_runs_zfs_destroy
    exec = stopped_exec
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--purge', '--yes']) }
    assert_includes exec.runs, 'zfs destroy tank/bhyve/pod35'
  end

  def test_destroy_refuses_running_vm
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod35' => true })
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod35', '--yes']) }
    assert_match(/running/, err.message)
  end

  def test_destroy_unknown_vm
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: stopped_exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', '--yes']) }
  end

  def test_dry_run_writes_nothing
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod35' => false }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--purge', '--yes']) }
    assert_equal before, File.read(@inv), 'dry-run must not change the inventory file'
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_destroy_command.rb`
Expected: FAIL — `cannot load such file -- vmctl/commands/destroy`.

- [ ] **Step 3: Implement `lib/vmctl/commands/destroy.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/destroy.rb
require 'optparse'
require_relative 'base'

module VMCtl
  module Commands
    class Destroy < Base
      def call(args)
        opts = parse(args)
        name = opts[:name]
        raise CommandError, 'destroy requires a VM name' unless name
        vm = vm_for(name) # raises CommandError for unknown VM
        raise CommandError, "#{name} is running — stop it first" if vm.running?(executor)

        confirm!(name) unless opts[:yes]

        executor.run("zfs destroy #{config.defaults.zpool}/#{name}") if opts[:purge]
        config.remove_vm(name)
        config.save(config.path) unless executor.dry_run?
        puts "destroyed #{name}#{opts[:purge] ? ' (dataset purged)' : ''}"
      end

      private

      def parse(args)
        o = {}
        parser = OptionParser.new do |p|
          p.on('--purge') { o[:purge] = true }
          p.on('--yes')   { o[:yes] = true }
        end
        rest = parser.parse(args)
        o[:name] = rest.shift
        o
      end

      def confirm!(name)
        $stdout.print "Destroy #{name}? type 'yes' to confirm: "
        $stdout.flush
        answer = $stdin.gets&.strip
        raise CommandError, 'aborted' unless answer == 'yes'
      end
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_destroy_command.rb` → all green.
Run: `ruby -Ilib -Itest test/run_all.rb` → all green.

- [ ] **Step 5: Commit-prep** — leave uncommitted.

---

## Task 8: CLI wiring + README + final verification

**Files:** Modify `lib/vmctl/cli.rb`, `README.md`

- [ ] **Step 1: Register the three commands in `lib/vmctl/cli.rb`.**

Add requires (with the other command requires):
```ruby
require_relative 'commands/create'
require_relative 'commands/import'
require_relative 'commands/destroy'
```

Add to the `COMMANDS` hash:
```ruby
    COMMANDS = {
      'list'    => Commands::List,
      'status'  => Commands::Status,
      'start'   => Commands::Start,
      'stop'    => Commands::Stop,
      'restart' => Commands::Restart,
      'console' => Commands::Console,
      'create'  => Commands::Create,
      'import'  => Commands::Import,
      'destroy' => Commands::Destroy
    }.freeze
```

Update the `USAGE` heredoc Commands section to include:
```
        create <name>         Allocate + provision a new VM.
        import <name>         Adopt an existing (zfs-recv'd) VM's disks.
        destroy <name>        Remove a VM (--purge also destroys its dataset).
```
(Insert these three lines after the `console` line and before `list`.)

- [ ] **Step 2: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS — all test files green.

- [ ] **Step 3: End-to-end dry-run smoke check (no FreeBSD needed)**

Run:
```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/configs" "$TMP/images" "$TMP/vms"
printf 'cpus=2\n' > "$TMP/configs/pod.conf"
printf 'defaults:\n  config_dir: %s/configs\n  vm_root: %s/vms\n  zpool: tank/bhyve\n  template: pod.conf\n  link_base: 10\n  image_dir: %s/images\n  root_size: 20G\n  root_from: null\nvms: {}\n' "$TMP" "$TMP" "$TMP" > "$TMP/inv.yml"
ruby -Ilib bin/vmctl -c "$TMP/inv.yml" -n create pod35 --network labs_vlan50 2>&1
echo "--- inventory unchanged? ---"; grep -c 'pod35' "$TMP/inv.yml"
```
Expected: dry-run logs `[dry-run] zfs create tank/bhyve/pod35`, `[dry-run] truncate -s 20G …` (to stderr), prints `created pod35 (link 10)`, and `grep -c pod35` prints `0` (inventory not written). (Note: the bridge check `ngctl info labs_vlan50:` will fail off-FreeBSD and raise a NetgraphError before provisioning — that is expected off-host; on a real host with the bridge present, the dry-run completes as described. For the smoke check off-host, expect the NetgraphError + exit 1, which itself confirms validation runs.)

- [ ] **Step 4: Update `README.md`** — replace the Usage command list and the Scope section.

In the Usage code block, add under the existing commands:
```
  create <name>        Allocate + provision a new VM (--network NET).
  import <name>        Adopt an existing (zfs-recv'd) VM's disks (--network NET).
  destroy <name>       Remove a VM (--purge also zfs-destroys its dataset).
```

Add a new section after Usage:
```markdown
## Provisioning

`create` lays down a per-VM ZFS dataset and raw image file(s), and (with
`--cloud-init FILE`) a NoCloud seed ISO. Defaults come from the `defaults:`
block (`image_dir`, `root_size`, `root_from`):

    vmctl create pod35 --network labs_vlan50          # single root disk from the default golden image
    vmctl create db1   --network labs_vlan50 --disk data:200G   # add a blank data disk
    vmctl create web1  --network labs_vlan50 --cloud-init ./web-userdata.yml --start

Templates stay opaque: vmctl creates exactly the disks in the VM's `disks:`
list — your `.conf` template is responsible for referencing those paths (and,
for cloud-init, declaring the AHCI-CD device that points at `<name>-seed.iso`).

`import <name> --network NET` adopts a VM whose dataset already exists (e.g.
arrived via `zfs recv`): it allocates a fresh `link`, scans `<vm_root>/<name>/`
for `*.raw`, and registers the VM without provisioning.

`destroy <name>` removes a VM from the inventory (refusing if it is running);
`--purge` also `zfs destroy`s the dataset. All three honor `-n/--dry-run`.
```

Replace the final Scope paragraph's "Provisioning … is a planned Phase 2." sentence with:
```markdown
vmctl manages VM **lifecycle**, **inventory**, and **provisioning**. It validates
(never creates) netgraph bridges — those are host infrastructure owned by your
`netgraph_setup` rc script.
```

- [ ] **Step 5: Final full suite**

Run: `ruby -Ilib -Itest test/run_all.rb` → all green.

- [ ] **Step 6: Commit-prep** — leave uncommitted; controller commits.

---

## Manual Verification (FreeBSD host, after merge)

On a real host with ZFS, an existing bridge, and a golden image in `image_dir`:

1. `vmctl -n create pod35 --network labs_vlan50` → prints the zfs/truncate plan, writes nothing.
2. `vmctl create pod35 --network labs_vlan50` → creates `tank/bhyve/pod35`, `pod35-root.raw`; registers `pod35` with an allocated link; `vmctl list` shows it.
3. `vmctl create db1 --network labs_vlan50 --disk data:200G --cloud-init ./ud.yml` → two disks + `db1-seed.iso`; inventory has `cloud_init.user_data`.
4. `vmctl create web1 --network labs_vlan50 --start` → created and booted (verify with `vmctl status web1`).
5. `zfs send`/`recv` a VM's dataset to another host, then `vmctl import <name> --network <net>` there → registered with a fresh link, disks discovered.
6. `vmctl destroy pod35` (stopped) → de-registered, dataset remains; `vmctl destroy pod35 --purge` → dataset gone. Running VM → refused.

---

## Self-Review

**Spec coverage:**
- New `defaults` (`image_dir`/`root_size`/`root_from`) + `add_vm`/`remove_vm` → Task 2.
- Size parse/format (grow check + import sizing) → Task 1.
- `Provisioner` (zfs create, raw create/clone/grow, image resolution) → Task 3.
- `CloudInit` (meta-data + verbatim user-data + makefs seed ISO) → Task 4.
- `create` (allocate, build disks from defaults+flags, validate-before-provision, mac modes, cloud-init, register, `--start`, dry-run) → Task 5.
- `import` (scan `*.raw`, fresh link, no provisioning) → Task 6.
- `destroy` (running-check, `--purge`, confirm/`--yes`, dry-run) → Task 7.
- CLI wiring + README + dry-run honored end-to-end → Tasks 5–8.

**Type consistency:** `Provisioner.new(executor, defaults)`, `CloudInit.new(executor)`, `Allocator.new(config)`, `Netgraph.new(executor)`, `Config#add_vm/#remove_vm/#save(path)/#path`, `VM#dir/#template_path/#running?`, `Sizes.parse/.human`, `Disk`/`VMEntry` field names — all match Phase 1 signatures and are used identically across Tasks 3–7.

**Placeholder scan:** No TBD/TODO; every code step shows complete code.

**Dry-run model (stated once, applied throughout):** validation is read-only and always runs; mutations are suppressed because `Executor#run` no-ops + logs every `zfs`/`truncate`/`cp`/`makefs` command in dry-run, and each command guards `Config#save` with `unless executor.dry_run?`. `add_vm` mutates only in memory, so `--start` can still render in dry-run.
```
