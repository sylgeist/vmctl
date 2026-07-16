# vmctl `clone` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `vmctl clone <source> <newname>` — provision a new VM as a fully independent ZFS copy of an existing one, with fresh identity (name/link/MAC) and inherited config.

**Architecture:** A new `Commands::Clone` (one command per file, like `create`/`import`) validates inputs and builds the new inventory entry, delegating the ZFS work to a new `Provisioner#clone_dataset` (snapshot → `send | recv` → rename disk files → drop UEFI vars → clean up snapshots, with rollback on failure). A new `Executor#pipe` provides the `send | recv` pipeline without a shell string, preserving the argv-only safety property.

**Tech Stack:** Ruby ≥ 4.0, stdlib only (`open3`, `optparse`, `fileutils`), minitest. No gems.

## Global Constraints

- **No gems** — Ruby stdlib + FreeBSD base tools (`zfs`, `mv`, `rm`) only.
- **Ruby ≥ 4.0**; every file starts with `# frozen_string_literal: true`.
- **Shell-out only through `Executor`**, always as separate argv (never a shell string).
- **`-n/--dry-run`**: mutating commands log-and-noop; the inventory file is never written.
- **Tests run with:** `ruby -Ilib -Itest test/run_all.rb` (auto-discovers `test/test_*.rb`).
- Source of truth for the clone is the **source's inventory entry** — no scan of the source dataset.

---

### Task 1: `Executor#pipe` (and `FakeExecutor#pipe`)

**Files:**
- Modify: `lib/vmctl/executor.rb`
- Modify: `test/test_helper.rb` (add `pipe` to `FakeExecutor`)
- Test: `test/test_executor.rb`

**Interfaces:**
- Produces: `Executor#pipe(argv1, argv2) -> String` — runs `argv1 | argv2` with no shell, returns the final stage's stdout, raises `ExecutorError` on any non-zero stage; no-op returning `""` in dry-run.
- Produces: `FakeExecutor#pipe(argv1, argv2) -> String` records `[argv1, argv2]` into `#pipes`, returns `""`.

- [ ] **Step 1: Write the failing tests** in `test/test_executor.rb` (append inside the class):

```ruby
  def test_pipe_passes_stdout_through
    # echo hi | cat  ->  "hi\n"
    assert_equal "hi\n", VMCtl::Executor.new.pipe(['echo', 'hi'], ['cat'])
  end

  def test_pipe_raises_when_a_stage_fails
    assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.pipe(['echo', 'hi'], ['false']) }
  end

  def test_pipe_is_noop_in_dry_run
    assert_equal "", VMCtl::Executor.new(dry_run: true).pipe(['echo', 'hi'], ['cat'])
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_executor.rb`
Expected: FAIL — `NoMethodError: undefined method 'pipe'`.

- [ ] **Step 3: Implement `Executor#pipe`** in `lib/vmctl/executor.rb` (add after `capture`):

```ruby
    # Run argv1 | argv2 with no shell. Returns argv2's stdout. Raises on any
    # non-zero stage. No-op (logs only) in dry-run, returning "".
    def pipe(argv1, argv2)
      if @dry_run
        VMCtl.logger.info("[dry-run] #{argv1.join(' ')} | #{argv2.join(' ')}")
        return ""
      end
      VMCtl.logger.debug("exec: #{argv1.join(' ')} | #{argv2.join(' ')}")
      out, statuses = Open3.pipeline_r(argv1, argv2) { |o, ts| [o.read, ts.map(&:value)] }
      statuses.each_with_index do |status, i|
        next if status.success?
        argv = i.zero? ? argv1 : argv2
        raise ExecutorError, "#{argv.first} exited with status #{status.exitstatus} in pipeline"
      end
      out
    rescue Errno::ENOENT => e
      raise ExecutorError, "command not found in pipeline: #{e.message}"
    end
```

- [ ] **Step 4: Add `pipe` to `FakeExecutor`** in `test/test_helper.rb`:

Add `:pipes` to the `attr_reader`, initialize `@pipes = []` in `initialize`, and add the method:

```ruby
  def pipe(argv1, argv2)
    @pipes << [argv1, argv2]
    ""
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_executor.rb`
Expected: PASS (all tests, including the three new ones).

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/executor.rb test/test_executor.rb test/test_helper.rb
git commit -m "feat(executor): add pipe() for shell-free argv pipelines"
```

---

### Task 2: `Provisioner#clone_dataset`

**Files:**
- Modify: `lib/vmctl/provisioner.rb`
- Test: `test/test_provisioner.rb`

**Interfaces:**
- Consumes: `Executor#run`, `Executor#pipe` (Task 1); `VM#name`, `VM#dir`, `VM#entry.disks` (each `Disk` has `.file`).
- Produces: `Provisioner#clone_dataset(source_vm, dest_vm) -> nil`. Emits, in order: `zfs snapshot <zpool>/<src>@vmctl-clone-<dst>`; `pipe(['zfs','send',<snap>], ['zfs','recv',<zpool>/<dst>])`; one `mv <dst.dir>/<src_file> <dst.dir>/<dst_file>` per disk whose file name changed (index-aligned `source_vm.entry.disks` ↔ `dest_vm.entry.disks`); `rm -f <dst.dir>/<src>-uefi-vars.fd`; `zfs destroy` of the source snapshot and the received snapshot. On any failure after the snapshot, best-effort `zfs destroy` of the dest dataset and source snapshot, then re-raise.

- [ ] **Step 1: Write the failing tests.** Create/append `test/test_provisioner.rb`. If the file already exists, add these methods inside the existing class; otherwise create it with this scaffold:

```ruby
# frozen_string_literal: true
# test/test_provisioner.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/provisioner'
require 'vmctl/vm'

class TestProvisioner < Minitest::Test
  def defaults
    VMCtl::Config.new({ 'defaults' => { 'zpool' => 'tank/bhyve', 'vm_root' => '/bhyve' } }).defaults
  end

  def vm(name, files)
    disks = files.map { |f| VMCtl::Disk.new(file: f, size: '1G', from: nil) }
    entry = VMCtl::VMEntry.new(name: name, disks: disks)
    VMCtl::VM.new(entry, defaults)
  end

  def test_clone_dataset_emits_snapshot_send_recv_rename_and_cleanup
    exec = FakeExecutor.new
    src = vm('pod34', ['pod34-root.raw'])
    dst = vm('web1',  ['web1-root.raw'])
    VMCtl::Provisioner.new(exec, defaults).clone_dataset(src, dst)

    assert_includes exec.runs, ['zfs', 'snapshot', 'tank/bhyve/pod34@vmctl-clone-web1']
    assert_includes exec.pipes,
                    [['zfs', 'send', 'tank/bhyve/pod34@vmctl-clone-web1'],
                     ['zfs', 'recv', 'tank/bhyve/web1']]
    assert_includes exec.runs, ['mv', '/bhyve/web1/pod34-root.raw', '/bhyve/web1/web1-root.raw']
    assert_includes exec.runs, ['rm', '-f', '/bhyve/web1/pod34-uefi-vars.fd']
    assert_includes exec.runs, ['zfs', 'destroy', 'tank/bhyve/pod34@vmctl-clone-web1']
    assert_includes exec.runs, ['zfs', 'destroy', 'tank/bhyve/web1@vmctl-clone-web1']
  end

  def test_clone_dataset_skips_mv_when_disk_name_unchanged
    # An oddly-named (non-<src>- prefixed) disk keeps its name: no mv for it.
    exec = FakeExecutor.new
    src = vm('pod34', ['data.raw'])
    dst = vm('web1',  ['data.raw'])
    VMCtl::Provisioner.new(exec, defaults).clone_dataset(src, dst)
    refute(exec.runs.any? { |a| a.first == 'mv' }, 'unchanged disk name must not be moved')
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_provisioner.rb`
Expected: FAIL — `NoMethodError: undefined method 'clone_dataset'`.

- [ ] **Step 3: Implement `clone_dataset`** in `lib/vmctl/provisioner.rb` (add a constant and methods inside the class):

```ruby
    SNAP_PREFIX = 'vmctl-clone-'

    # Full independent copy of source_vm's dataset into dest_vm's, via
    # snapshot + send|recv. Renames disk files to the dest's name prefix, drops
    # the copied UEFI vars store, and removes both snapshots. Rolls back the
    # received dataset on failure.
    def clone_dataset(source_vm, dest_vm)
      snap = "#{@defaults.zpool}/#{source_vm.name}@#{SNAP_PREFIX}#{dest_vm.name}"
      dest_ds = "#{@defaults.zpool}/#{dest_vm.name}"
      @exec.run('zfs', 'snapshot', snap)
      begin
        @exec.pipe(['zfs', 'send', snap], ['zfs', 'recv', dest_ds])
        rename_clone_disks(source_vm, dest_vm)
        @exec.run('rm', '-f', File.join(dest_vm.dir, "#{source_vm.name}-uefi-vars.fd"))
      rescue StandardError
        destroy_quietly(dest_ds)
        destroy_quietly(snap)
        raise
      end
      destroy_quietly(snap)
      destroy_quietly("#{dest_ds}@#{SNAP_PREFIX}#{dest_vm.name}")
      nil
    end
```

and these privates (below the existing `private` marker):

```ruby
    def rename_clone_disks(source_vm, dest_vm)
      source_vm.entry.disks.zip(dest_vm.entry.disks).each do |src_disk, dst_disk|
        next if src_disk.file == dst_disk.file
        @exec.run('mv',
                  File.join(dest_vm.dir, src_disk.file),
                  File.join(dest_vm.dir, dst_disk.file))
      end
    end

    def destroy_quietly(target)
      @exec.run('zfs', 'destroy', target)
    rescue ExecutorError
      nil
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_provisioner.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/provisioner.rb test/test_provisioner.rb
git commit -m "feat(provisioner): add clone_dataset (snapshot + send|recv + rename)"
```

---

### Task 3: `Commands::Clone` — core clone, inheritance, and CLI registration

**Files:**
- Create: `lib/vmctl/commands/clone.rb`
- Modify: `lib/vmctl/cli.rb` (require + `COMMANDS` entry + usage line)
- Test: `test/test_clone_command.rb`

**Interfaces:**
- Consumes: `Base#vm_for`, `Base#positive_int!`, `Base#valid_size!`; `Allocator#next_link`, `Allocator#generate_mac(name, index=0)`; `Provisioner#clone_dataset` (Task 2); `Netgraph#ensure_bridge!`; `Commands::Start#call`.
- Produces: `Commands::Clone < Base` with `#call(args)`. Positional `args`: `<source> <newname>`. Flags: `--network`, `--mac`, `--cpus`, `--memory`, `--autostart`, `--force`, `--start`.

- [ ] **Step 1: Write the failing tests.** Create `test/test_clone_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_clone_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/clone'
require 'tmpdir'

class TestCloneCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @config_dir = File.join(@dir, 'configs'); FileUtils.mkdir_p(@config_dir)
    File.write(File.join(@config_dir, 'pod.conf'), "cpus=2\n")
    @vm_root = File.join(@dir, 'vms'); FileUtils.mkdir_p(@vm_root)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        config_dir: #{@config_dir}
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        template: pod.conf
        link_base: 10
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          mac: 5a:9c:fc:11:22:33
          autostart: true
          cpus: 4
          memory: 8G
          graphics: true
          efi_vars: true
          disks:
            - { file: pod34-root.raw, size: 20G }
            - { file: pod34-data.raw, size: 50G }
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

  # Source stopped (no vmm device) + inherited bridge present.
  def ready_exec(extra = {})
    FakeExecutor.new(probes: { '/dev/vmm/pod34' => false,
                               'ngctl info labs_vlan50:' => true }.merge(extra))
  end

  def test_clone_copies_dataset_and_registers_with_fresh_identity
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'web1']) }

    assert_includes exec.runs, ['zfs', 'snapshot', 'tank/bhyve/pod34@vmctl-clone-web1']
    assert_includes exec.pipes,
                    [['zfs', 'send', 'tank/bhyve/pod34@vmctl-clone-web1'],
                     ['zfs', 'recv', 'tank/bhyve/web1']]
    assert_match(/cloned pod34 -> web1 \(link 11\)/, out)

    e = VMCtl::Config.load(@inv).vms.fetch('web1')
    assert_equal 11, e.link                 # fresh: next free after pod34's 10
    refute_equal 'pod34', e.name
    refute_equal '5a:9c:fc:11:22:33', e.mac # fresh MAC, not the source's
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, e.mac)
    assert_equal false, e.autostart         # reset off
  end

  def test_clone_inherits_config_fields
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1']) }
    e = VMCtl::Config.load(@inv).vms.fetch('web1')
    assert_equal 'labs_vlan50', e.network
    assert_equal 'pod.conf', e.config
    assert_equal 4, e.cpus
    assert_equal '8G', e.memory
    assert_equal true, e.graphics
    assert_equal true, e.efi_vars
  end

  def test_clone_renames_disk_files_to_new_prefix
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1']) }
    files = VMCtl::Config.load(@inv).vms.fetch('web1').disks.map(&:file)
    assert_equal ['web1-root.raw', 'web1-data.raw'], files
    assert_includes exec.runs, ['mv', File.join(@vm_root, 'web1', 'pod34-root.raw'),
                                File.join(@vm_root, 'web1', 'web1-root.raw')]
  end

  def test_clone_rejects_unknown_source
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: ready_exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', 'web1']) }
  end

  def test_clone_rejects_duplicate_new_name
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: ready_exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'pod34']) }
    assert_match(/exists/, err.message)
  end

  def test_clone_requires_source_and_name
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: ready_exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_clone_command.rb`
Expected: FAIL — cannot load `vmctl/commands/clone`.

- [ ] **Step 3: Implement the command.** Create `lib/vmctl/commands/clone.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/clone.rb
require 'optparse'
require_relative 'base'
require_relative '../allocator'
require_relative '../netgraph'
require_relative '../provisioner'
require_relative 'start'

module VMCtl
  module Commands
    class Clone < Base
      def call(args)
        opts = parse(args)
        source_name = opts[:source]
        new_name = opts[:name]
        raise CommandError, 'clone requires a source VM and a new name' unless source_name && new_name

        source_vm = vm_for(source_name) # raises CommandError for unknown VM
        raise CommandError, "VM '#{new_name}' already exists" if config.vms.key?(new_name)

        entry = build_entry(source_vm.entry, new_name, opts)
        dest_vm = VM.new(entry, config.defaults)
        provisioner = Provisioner.new(executor, config.defaults)
        validate!(source_vm, dest_vm, opts)

        provisioner.clone_dataset(source_vm, dest_vm)
        config.add_vm(entry)
        config.save(config.path) unless executor.dry_run?
        puts "cloned #{source_name} -> #{new_name} (link #{entry.link})"

        Start.new(config: config, executor: executor).call([new_name]) if opts[:start]
      end

      private

      def parse(args)
        o = {}
        parser = OptionParser.new do |p|
          p.on('--network NET') { |v| o[:network] = v }
          p.on('--mac MAC')     { |v| o[:mac] = v }
          p.on('--cpus N')      { |v| o[:cpus] = v }
          p.on('--memory SIZE') { |v| o[:memory] = v }
          p.on('--autostart')   { o[:autostart] = true }
          p.on('--force')       { o[:force] = true }
          p.on('--start')       { o[:start] = true }
        end
        rest = parser.parse(args)
        o[:source] = rest.shift
        o[:name]   = rest.shift
        o
      end

      def build_entry(src, new_name, opts)
        allocator = Allocator.new(config)
        VMEntry.new(
          name: new_name,
          config: src.config,
          network: opts[:network] || src.network,
          link: allocator.next_link,
          mac: clone_mac(allocator, new_name, src.mac, opts),
          autostart: !!opts[:autostart],
          disks: rename_disks(src.name, new_name, src.disks),
          cloud_init: src.cloud_init,
          iso: nil,
          options: src.options,
          mtu: src.mtu,
          networks: clone_networks(allocator, new_name, src.networks),
          cpus: opts[:cpus] ? positive_int!(opts[:cpus], '--cpus') : src.cpus,
          memory: opts[:memory] ? valid_size!(opts[:memory], '--memory') : src.memory,
          graphics: src.graphics,
          efi_vars: src.efi_vars,
          rtc_localtime: src.rtc_localtime,
          memory_wired: src.memory_wired,
          smbios: src.smbios
        )
      end

      # nil source MAC -> nil (bhyve auto); otherwise a fresh deterministic MAC.
      # --mac overrides the primary.
      def clone_mac(allocator, new_name, source_mac, opts)
        return opts[:mac] if opts[:mac]
        return nil if source_mac.nil?
        allocator.generate_mac(new_name)
      end

      # Additional NICs: keep bridge/mtu; regenerate a distinct MAC per index
      # (index 1+), leaving nil MACs as nil.
      def clone_networks(allocator, new_name, networks)
        return networks if networks.nil? || networks.empty?
        networks.each_with_index.map do |nic, i|
          mac = nic.mac.nil? ? nil : allocator.generate_mac(new_name, i + 1)
          Nic.new(bridge: nic.bridge, mtu: nic.mtu, mac: mac)
        end
      end

      # Swap the source name prefix on each disk file; leave non-prefixed as-is.
      def rename_disks(source_name, new_name, disks)
        disks.map do |d|
          new_file = d.file.sub(/\A#{Regexp.escape(source_name)}-/, "#{new_name}-")
          Disk.new(file: new_file, size: d.size, from: d.from)
        end
      end

      def validate!(source_vm, dest_vm, opts)
        raise CommandError, "dataset dir already exists: #{dest_vm.dir}" if File.exist?(dest_vm.dir)
        if source_vm.running?(executor) && !opts[:force]
          raise CommandError,
                "#{source_vm.name} is running — stop it first (or pass --force for a crash-consistent clone)"
        end
        warn "warning: #{source_vm.name} is running; clone is crash-consistent" if source_vm.running?(executor)
        ng = Netgraph.new(executor)
        dest_vm.nic_bridges.each { |b| ng.ensure_bridge!(b) }
      end
    end
  end
end
```

- [ ] **Step 4: Register in the CLI.** In `lib/vmctl/cli.rb`:

Add after the `require_relative 'commands/import'` line:
```ruby
require_relative 'commands/clone'
```
Add to the `COMMANDS` hash after the `'import'` entry:
```ruby
      'clone'   => Commands::Clone,
```
Add to `USAGE` after the `import <name>` line:
```
        clone <src> <name>    Clone an existing VM into a new independent copy.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_clone_command.rb`
Expected: PASS (all 6 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/commands/clone.rb lib/vmctl/cli.rb test/test_clone_command.rb
git commit -m "feat(cli): add clone command with fresh identity and inherited config"
```

---

### Task 4: Clone guards & overrides (force, dry-run, network/mac, auto-MAC preservation)

**Files:**
- Test: `test/test_clone_command.rb` (add cases)
- Modify (only if a test surfaces a gap): `lib/vmctl/commands/clone.rb`

**Interfaces:**
- Consumes: everything from Task 3. No new public interface — this task verifies the guard/override branches already written in Task 3 and fixes any that misbehave.

- [ ] **Step 1: Write the failing/again-green tests.** Append to `test/test_clone_command.rb`:

```ruby
  def test_clone_refuses_running_source_without_force
    exec = ready_exec('/dev/vmm/pod34' => true) # source appears running
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'web1']) }
    assert_match(/running/, err.message)
  end

  def test_clone_allows_running_source_with_force
    exec = ready_exec('/dev/vmm/pod34' => true)
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1', '--force']) }
    assert VMCtl::Config.load(@inv).vms.key?('web1')
  end

  def test_clone_network_override
    exec = ready_exec('ngctl info other_vlan:' => true)
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1', '--network', 'other_vlan']) }
    assert_equal 'other_vlan', VMCtl::Config.load(@inv).vms.fetch('web1').network
  end

  def test_clone_mac_override
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1', '--mac', '02:aa:bb:cc:dd:ee']) }
    assert_equal '02:aa:bb:cc:dd:ee', VMCtl::Config.load(@inv).vms.fetch('web1').mac
  end

  def test_clone_preserves_nil_source_mac_as_auto
    # Rewrite the source to have no MAC (bhyve auto); clone must stay auto.
    inv = File.read(@inv).sub('mac: 5a:9c:fc:11:22:33', 'mac:')
    File.write(@inv, inv)
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1']) }
    assert_nil VMCtl::Config.load(@inv).vms.fetch('web1').mac
  end

  def test_clone_dry_run_writes_nothing
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false, 'ngctl info labs_vlan50:' => true },
                            dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1']) }
    assert_equal before, File.read(@inv), 'dry-run must not change the inventory file'
  end
```

> The `--start` flag is wired exactly as in `create` (`Start.new(...).call([new_name])`). `create`'s test suite deliberately does not unit-test `--start` because `Start` forks and spawns a real `bhyve`; do not add a `--start` unit test here either. The wiring is exercised end-to-end on a real host.

- [ ] **Step 2: Run the tests**

Run: `ruby -Ilib -Itest test/test_clone_command.rb`
Expected: The guard/override/dry-run tests PASS against the Task 3 implementation. If any fail, fix `lib/vmctl/commands/clone.rb` minimally and re-run.

- [ ] **Step 3: Run the whole suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS — no regressions in any file.

- [ ] **Step 4: Commit**

```bash
git add test/test_clone_command.rb lib/vmctl/commands/clone.rb
git commit -m "test(clone): cover force, dry-run, network/mac overrides, auto-MAC"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Document `clone` in the Usage command list.** In `README.md`, in the `## Usage` fenced block, add after the `import <name>` line:

```
  clone <src> <name>   Clone an existing VM into a new independent copy.
```

- [ ] **Step 2: Add a Provisioning subsection.** In `README.md`, in the `## Provisioning` section (after the `import` paragraphs), add:

````markdown
### Cloning

`clone <source> <newname>` provisions a new VM as a full independent copy of an
existing one — the homelab "golden template" workflow, though any VM can be a
source:

    vmctl clone pod34 web1                       # inherit pod34's bridge
    vmctl clone pod34 web1 --network other_vlan  # place on a different bridge
    vmctl clone pod34 web1 --cpus 2 --memory 4G --start

The clone's disks are copied via `zfs snapshot` + `zfs send | zfs recv`, so the
clone and source share no ZFS dependency — either can be `destroy`ed later
independently. The source must be stopped (pass `--force` to clone a running VM
with a crash-consistent snapshot).

Inherited from the source: template (`config`), `cpus`, `memory`, `graphics`,
`efi_vars`, `rtc_localtime`, `memory_wired`, `smbios`, `cloud_init`, and any
additional `networks:`. Reset fresh: `name`, `link`, and MAC (the primary MAC
is regenerated unless the source used bhyve auto-MAC, in which case the clone
stays auto; `--mac` overrides). `autostart` defaults off. An installer `iso:` is
not carried over, and UEFI vars are regenerated pristine on the clone's first
start.
````

- [ ] **Step 3: Verify the full suite still passes** (docs change shouldn't break tests, but confirm the tree is green before committing):

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document the clone command"
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** Task 1 = `Executor#pipe`; Task 2 = `Provisioner#clone_dataset` (snapshot/send/recv/rename/rm-uefi/cleanup/rollback); Task 3 = command, inherit/reset policy, MAC rules, disk rename, CLI registration; Task 4 = stopped-source guard + `--force`, dry-run, `--network`/`--mac` overrides, auto-MAC preservation; Task 5 = docs. (`--start` wiring is identical to `create` and, like `create`, intentionally not unit-tested since `Start` spawns real `bhyve`.) The spec's "drop `iso`" and "don't preserve UEFI vars" are covered in Tasks 3 and 2 respectively.
- **Rollback** (spec §Error handling) lives in `clone_dataset`'s `rescue` (Task 2). A dedicated rollback unit test is optional; if added, inject a `FakeExecutor` whose `pipe` raises and assert a `zfs destroy` of the dest dataset was recorded.
- **Naming consistency:** snapshot label is `vmctl-clone-<dst>` everywhere; the command builds `disks` with `rename_disks`, and `Provisioner#rename_clone_disks` moves files by comparing the index-aligned source/dest disk lists — the two never recompute the prefix independently.
