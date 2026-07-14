# vmctl `info` verb Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only `vmctl info [<name>...] [--all]` verb that prints a per-VM resource summary (run state + resolved cpus/memory/disks/networks).

**Architecture:** A new `Commands::Info < Commands::Base` command reads existing accessors only — `vm.resolved_config` (single source of truth for cpus/memory/wired, same values the VM boots with), `vm.entry.disks` + `vm.disk_paths` for disk rows, and `vm.entry` NIC fields for networks. It reuses `Base#targets` for target resolution and the same liveness helpers `status` uses for the header state. Then it's registered in `cli.rb`. No changes to `config.rb`, `config_renderer.rb`, or `vm.rb`.

**Tech Stack:** Ruby (no framework), Minitest, `FakeExecutor` test double (`test/test_helper.rb`).

## Global Constraints

- Every Ruby file starts with `# frozen_string_literal: true` and a `# lib/...` (or `# test/...`) path comment, matching sibling files.
- Read-only: `info` must never mutate the inventory or shell out beyond the liveness probes `status` already performs (`test -e /dev/vmm/<name>`, `kill -0 <pid>`). No new bhyve/ps introspection.
- Configured allocation only — no live utilization (RSS, CPU%, on-disk image size).
- Follow existing command shape: subclass `Commands::Base`, use `targets`, raise `Commands::CommandError` for unknown VMs (inherited via `vm_for`).
- cpus/memory/wired come from `vm.resolved_config` (bhyve keys `cpus`, `memory.size`, `memory.wired`). Disk **size** comes from `vm.entry.disks` (it is not a bhyve boot key); disk **path** from `vm.disk_paths` (identical to the resolved `pci.0.3.N.path`).
- Spec: `docs/superpowers/specs/2026-07-14-vmctl-info-verb-design.md`.

---

## File Structure

- **Create:** `lib/vmctl/commands/info.rb` — the `Commands::Info` command (all formatting logic).
- **Create:** `test/test_info_command.rb` — Minitest coverage for the command in isolation.
- **Modify:** `lib/vmctl/cli.rb` — register the verb: one `require_relative`, one `COMMANDS` entry, one `USAGE` line.
- **No change:** `test/run_all.rb` globs `test/test_*.rb`, so it picks up the new test file automatically.

---

## Task 1: The `info` command

**Files:**
- Create: `lib/vmctl/commands/info.rb`
- Test: `test/test_info_command.rb`

**Interfaces:**
- Consumes (all existing, do not change):
  - `Commands::Base#targets(names, all:)` → `Array<VMCtl::VM>`
  - `Commands::Base#executor`
  - `VM#running?(executor)`, `VM#supervisor_alive?(executor)`, `VM#read_pid`
  - `VM#resolved_config` → `Hash{String=>String}` with keys `'cpus'`, `'memory.size'`, optional `'memory.wired' => 'true'`
  - `VM#entry` → `VMEntry` (fields `disks`, `network`, `link`, `networks`); `VMEntry#disks` → `Array<Disk>` where `Disk#file`, `Disk#size`; `VMEntry#networks` → `Array<Nic>` or `nil` where `Nic#bridge`
  - `VM#disk_paths` → `Array<String>` (absolute image paths, same order as `entry.disks`)
- Produces: `Commands::Info` with a public `#call(args)` that prints one block per resolved target, blocks joined by a blank line.

- [ ] **Step 1: Write the failing test file**

Create `test/test_info_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_info_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/info'

class TestInfoCommand < Minitest::Test
  # Builds an inventory with one or two VMs and a flavor template on disk.
  # Returns [config, run_dir] — run_dir is a real tmpdir so pidfiles can be
  # written to exercise the running/stale header branches.
  def load_config(second: false)
    dir = Dir.mktmpdir
    run_dir = Dir.mktmpdir
    File.write(File.join(dir, 'pod.conf'),
               "cpus=1\nmemory.size=1G\nlpc.com1.path=/dev/nmdm%(link)A\n")
    vms = +<<~YAML
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          cpus: 2
          memory: 4G
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    if second
      vms << <<~YAML
        pod35:
          config: pod.conf
          network: labs_vlan50
          link: 11
          cpus: 1
          memory: 2G
          disks: [{ file: pod35-root.raw, size: 20G }]
      YAML
    end
    inv = <<~YAML + vms
      defaults:
        config_dir: #{dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
    YAML
    f = Tempfile.new(['inv', '.yml'])
    f.write(inv)
    f.flush
    [VMCtl::Config.load(f.path), run_dir]
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def cmd(config, exec)
    VMCtl::Commands::Info.new(config: config, executor: exec)
  end

  def test_info_stopped_vm_shows_allocation
    config, = load_config
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^pod34: stopped$/, out)
    assert_match(/^  cpus\s+2$/, out)
    assert_match(/^  memory\s+4G$/, out)
    assert_match(%r{^  disks\s+root\s+20G\s+/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(/^  network\s+labs_vlan50\s+link 10$/, out)
  end

  def test_info_unknown_vm_raises
    config, = load_config
    exec = FakeExecutor.new
    assert_raises(VMCtl::Commands::CommandError) { cmd(config, exec).call(['ghost']) }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Itest test/test_info_command.rb`
Expected: FAIL — `cannot load such file -- vmctl/commands/info` (the require at the top can't resolve).

- [ ] **Step 3: Write the command**

Create `lib/vmctl/commands/info.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/info.rb
require_relative 'base'

module VMCtl
  module Commands
    # Read-only per-VM resource summary: run state plus the resolved allocation
    # (cpus/memory/disks/networks). Complements `status` (liveness only) and
    # `dump` (the full rendered bhyve config).
    class Info < Base
      def call(args)
        all = args.delete('--all')
        vms = targets(args, all: all || args.empty?)
        puts vms.map { |vm| block_for(vm) }.join("\n\n")
      end

      private

      def block_for(vm)
        lines = ["#{vm.name}: #{state(vm)}"]
        lines << row('cpus', cpus(vm))
        lines << row('memory', memory(vm))
        labeled('disks', disk_rows(vm), lines)
        labeled('network', net_rows(vm), lines)
        lines.join("\n")
      end

      # A label + value line; the label column is padded so values align.
      def row(label, value)
        format('  %-8s %s', label, value)
      end

      # Emit rows for a repeatable section: the label appears only on the first
      # row, continuation rows keep the alignment with a blank label.
      def labeled(label, rows, lines)
        rows.each_with_index do |value, i|
          lines << row(i.zero? ? label : '', value)
        end
      end

      def state(vm)
        return 'stopped' unless vm.running?(executor)
        return "running (pid #{vm.read_pid})" if vm.supervisor_alive?(executor)
        'stale'
      end

      def cpus(vm)
        vm.resolved_config['cpus']
      end

      def memory(vm)
        mem = vm.resolved_config['memory.size']
        vm.resolved_config['memory.wired'] == 'true' ? "#{mem}  (wired)" : mem
      end

      def disk_rows(vm)
        vm.entry.disks.zip(vm.disk_paths).map do |disk, path|
          suffix = disk.file.sub(/\A#{Regexp.escape(vm.name)}-/, '').sub(/\.raw\z/, '')
          format('%-6s %-6s %s', suffix, disk.size, path)
        end
      end

      def net_rows(vm)
        e = vm.entry
        rows = []
        rows << "#{e.network}  link #{e.link}" unless e.network.nil? || e.network == 'none'
        (e.networks || []).each { |n| rows << n.bridge }
        rows
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Itest test/test_info_command.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Add the running / stale / wired / multi-disk-nic / --all tests**

Append these methods inside `class TestInfoCommand` in `test/test_info_command.rb`:

```ruby
  def test_info_running_vm_shows_pid
    config, run_dir = load_config
    File.write(File.join(run_dir, 'pod34.pid'), "4821")
    exec = FakeExecutor.new(probes: { 'test -e' => true, 'kill -0' => true })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^pod34: running \(pid 4821\)$/, out)
  end

  def test_info_stale_vm
    config, = load_config
    # vmm device present but no live supervisor (kill -0 fails).
    exec = FakeExecutor.new(probes: { 'test -e' => true, 'kill -0' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^pod34: stale$/, out)
  end

  def test_info_wired_memory
    config, = load_config
    config.vms['pod34'].memory_wired = true
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^  memory\s+4G\s+\(wired\)$/, out)
  end

  def test_info_multi_disk_and_nic
    config, = load_config
    e = config.vms['pod34']
    e.disks << VMCtl::Disk.new(file: 'pod34-data.raw', size: '100G', from: nil)
    e.networks = [VMCtl::Nic.new(bridge: 'mgmt0', mtu: nil, mac: nil)]
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(%r{^  disks\s+root\s+20G\s+/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(%r{^\s+data\s+100G\s+/bhyve/pod34/pod34-data\.raw$}, out)
    assert_match(/^  network\s+labs_vlan50\s+link 10$/, out)
    assert_match(/^\s+mgmt0$/, out)
  end

  def test_info_all_prints_a_block_per_vm
    config, = load_config(second: true)
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['--all']) }
    assert_match(/^pod34: stopped$/, out)
    assert_match(/^pod35: stopped$/, out)
    # blocks are separated by a blank line
    assert_match(/\n\npod35:/, out)
  end
```

- [ ] **Step 6: Run the full test file to verify it passes**

Run: `ruby -Itest test/test_info_command.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 7: Commit**

```bash
git add lib/vmctl/commands/info.rb test/test_info_command.rb
git commit -m "feat(info): per-VM resource summary command"
```

---

## Task 2: Register the `info` verb in the CLI

**Files:**
- Modify: `lib/vmctl/cli.rb` (require block ~line 10-25; `USAGE` heredoc ~line 31-58; `COMMANDS` hash ~line 60-77)
- Test: `test/test_cli.rb`

**Interfaces:**
- Consumes: `Commands::Info` (Task 1).
- Produces: `COMMANDS['info']` resolves to `Commands::Info`; `USAGE` lists `info`.

- [ ] **Step 1: Write the failing test**

Add to `test/test_cli.rb` (inside the existing test class; if the file wraps calls in a helper, follow that file's existing pattern for asserting on `COMMANDS`/`USAGE`):

```ruby
  def test_info_verb_registered
    assert_equal VMCtl::Commands::Info, VMCtl::CLI::COMMANDS['info']
    assert_match(/^\s+info /, VMCtl::CLI::USAGE)
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Itest test/test_cli.rb`
Expected: FAIL — `COMMANDS['info']` is `nil`, so `assert_equal` fails (and/or `Commands::Info` is not yet required by `cli.rb`).

- [ ] **Step 3: Add the require**

In `lib/vmctl/cli.rb`, add after `require_relative 'commands/status'`:

```ruby
require_relative 'commands/info'
```

- [ ] **Step 4: Add the USAGE line**

In the `USAGE` heredoc, add directly under the `status` line:

```
    info [name|--all]     Resource summary: cpus, memory, disks, networks.
```

- [ ] **Step 5: Add the COMMANDS entry**

In the `COMMANDS` hash, add under the `'status'` entry:

```ruby
      'info'    => Commands::Info,
```

- [ ] **Step 6: Run the CLI test to verify it passes**

Run: `ruby -Itest test/test_cli.rb`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `ruby -Itest test/run_all.rb` (`run_all.rb` globs `test/test_*.rb`, so the new file is picked up automatically — no edit needed).
Expected: PASS, all tests green.

- [ ] **Step 8: Commit**

```bash
git add lib/vmctl/cli.rb test/test_cli.rb
git commit -m "feat(cli): register info verb"
```

---

## Notes for the implementer

- `vm.resolved_config` renders the flavor template (`entry.config`, e.g. `pod.conf`) from `config_dir`. The test's `load_config` writes that template — if you build a config by hand elsewhere, the template file must exist or `resolved_config` raises. This matches `dump`'s existing behavior; do not add special handling.
- `FakeExecutor#success?` returns `true` for any probe not listed. That means an unqualified `FakeExecutor.new` reports every VM as running — always pass `probes: { 'test -e' => false }` when you want the stopped branch.
- The stale branch needs `test -e => true` and either no pidfile or `kill -0 => false`. The running branch additionally needs a real pidfile in `run_dir` so `read_pid` returns the number.

---

## Self-Review

- **Spec coverage:** verb + target resolution (Task 1 `call`, Task 2 registration); configured-allocation-only via `resolved_config` (Task 1 `cpus`/`memory`); disk size from `entry.disks`, path from `disk_paths` (Task 1 `disk_rows`); wired suffix (Task 1 `memory` + wired test); status-style header for running/stopped/stale (Task 1 `state` + tests); aligned per-VM block, blank-line separated for multi-target (`block_for`/`labeled` + `--all` test). All five spec test cases are present. ✓
- **Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows complete code. ✓
- **Type consistency:** `resolved_config` keyed by `'cpus'`/`'memory.size'`/`'memory.wired'` (strings) used consistently; `disk.file`/`disk.size`, `Nic#bridge`, `vm.disk_paths` match the structs in `config.rb` and `vm.rb`. ✓
