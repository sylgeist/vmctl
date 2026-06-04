# vmctl `dump` command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `vmctl dump <name>`, a read-only command that prints a VM's fully-resolved bhyve config by running bhyve with `config.dump=1` (which dumps the config and exits without booting).

**Architecture:** A new `VM#dump_command` reuses the existing `bhyve_argv` and inserts `-o config.dump=1` before the VM name; a thin `Commands::Dump` captures and prints its output via the existing `Executor`; the CLI registers the verb. No supervisor, no validation — config.dump resolves and exits before device setup.

**Tech Stack:** Ruby (stdlib only), minitest. Builds on the existing `VM`, `Commands::Base`, `Executor`, `CLI`.

**Spec:** `docs/superpowers/specs/2026-06-04-vmctl-dump-command-design.md`.

**Conventions:** `VMCtl` namespace; `# frozen_string_literal: true` + path-comment headers; thin commands delegating to domain objects; `Executor` is the sole shell-out boundary; tests via `ruby -Ilib -Itest test/run_all.rb`. Git commits in this repo require the sandbox disabled — implementers should NOT commit; the controller commits.

**Existing signatures used (verified against `main`):**
- `VM#bhyve_argv` → `['bhyve','-k',<tmpl>,'-o',"network=…",'-o',"link=…",(maybe '-o',"mac=…"),<name>]`.
- `Commands::Base` → `protected vm_for(name)` (raises `CommandError` for unknown VM), `config`, `executor`; `Commands::CommandError`.
- `Executor#capture(cmd)` → runs (even under dry-run), returns stdout, raises `ExecutorError` on non-zero.
- `CLI::COMMANDS` hash + `USAGE` heredoc + `require_relative` block.

---

## File Structure

```
lib/vmctl/
  vm.rb                  # MODIFY: add dump_command
  commands/dump.rb       # NEW: Commands::Dump
  cli.rb                 # MODIFY: require + register 'dump' + usage line
test/
  test_vm.rb             # MODIFY: add dump_command cases
  test_dump_command.rb   # NEW
```

---

## Task 1: `VM#dump_command`

**Files:** Modify `lib/vmctl/vm.rb`; modify `test/test_vm.rb`

- [ ] **Step 1: Add failing tests** — append inside `class TestVM` in `test/test_vm.rb` (before its final `end`):

```ruby
  def test_dump_command_inserts_config_dump_before_name
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(
      'bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 ' \
      '-o config.dump=1 pod34',
      vm.dump_command
    )
  end

  def test_dump_command_with_mac_keeps_order
    vm = VMCtl::VM.new(entry(mac: '5a:9c:fc:01:02:03'), defaults)
    assert_equal(
      'bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 ' \
      '-o mac=5a:9c:fc:01:02:03 -o config.dump=1 pod34',
      vm.dump_command
    )
  end
```

(`entry`/`entry(mac:)` and `defaults` helpers already exist in `test_vm.rb`.)

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_vm.rb`
Expected: FAIL — `NoMethodError: undefined method 'dump_command'`.

- [ ] **Step 3: Implement** — add this method to `lib/vmctl/vm.rb` (inside `class VM`, right after the `bhyve_command` method):

```ruby
    # Like bhyve_command, but appends `-o config.dump=1` so bhyve prints the
    # fully-resolved config and exits without booting.
    def dump_command
      argv = bhyve_argv
      argv.insert(-2, '-o', 'config.dump=1')
      argv.join(' ')
    end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_vm.rb`
Expected: PASS — existing VM tests plus the 2 new ones.

- [ ] **Step 5: Full suite + commit-prep**

Run: `ruby -Ilib -Itest test/run_all.rb` → all green. (Do NOT commit; controller commits.)

---

## Task 2: `Commands::Dump` + CLI wiring

**Files:** Create `lib/vmctl/commands/dump.rb`, `test/test_dump_command.rb`; modify `lib/vmctl/cli.rb`

- [ ] **Step 1: Write the failing test** — `test/test_dump_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_dump_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/dump'
require 'tempfile'

class TestDumpCommand < Minitest::Test
  INVENTORY = <<~YAML
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
        disks: []
  YAML

  def load_config
    f = Tempfile.new(['inv', '.yml'])
    f.write(INVENTORY)
    f.flush
    VMCtl::Config.load(f.path)
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_dump_captures_and_prints_resolved_config
    exec = FakeExecutor.new(captures: { 'config.dump=1' => "config.dump=1\ncpus=2\nmemory.size=4G\n" })
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    # The command passed to capture must include config.dump and the VM name.
    assert(exec.captures.any? { |c| c.include?('-o config.dump=1') && c.include?('pod34') })
    assert_match(/memory\.size=4G/, out)
  end

  def test_dump_requires_a_name
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call([]) }
  end

  def test_dump_unknown_vm
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost']) }
  end
end
```

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_dump_command.rb`
Expected: FAIL — `cannot load such file -- vmctl/commands/dump`.

- [ ] **Step 3: Create `lib/vmctl/commands/dump.rb`**

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/dump.rb
require_relative 'base'

module VMCtl
  module Commands
    # Prints a VM's fully-resolved bhyve config (bhyve -o config.dump=1), which
    # dumps the merged configuration and exits without booting. Read-only.
    class Dump < Base
      def call(args)
        name = args.first
        raise CommandError, 'dump requires a VM name' unless name
        vm = vm_for(name)
        puts executor.capture(vm.dump_command)
      end
    end
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_dump_command.rb`
Expected: PASS — 3 runs, 0 failures.

- [ ] **Step 5: Wire into `lib/vmctl/cli.rb`** — three edits.

(a) Add the require with the other command requires:
```ruby
require_relative 'commands/console'
require_relative 'commands/dump'
```

(b) Add the usage line in the `USAGE` heredoc, after the `console` line:
```
        console <name>        Attach to the VM's nmdm console.
        dump <name>           Print the VM's fully-resolved bhyve config (config.dump).
```

(c) Register it in `COMMANDS` (after `'console' => Commands::Console,`):
```ruby
      'console' => Commands::Console,
      'dump'    => Commands::Dump,
```

- [ ] **Step 6: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS — all green (existing + new dump tests).

- [ ] **Step 7: Smoke-check the binary**

Run: `ruby -Ilib bin/vmctl help | grep dump`
Expected: the `dump <name>` usage line prints.

Run (off-host; bhyve is absent here so expect a clean ExecutorError "command not found: bhyve", exit 1 — this proves wiring + capture path):
```bash
printf 'defaults:\n  config_dir: /tmp\n  link_base: 10\nvms:\n  pod34:\n    config: pod.conf\n    network: labs_vlan50\n    link: 10\n    disks: []\n' > "$TMPDIR/inv.yml"
ruby -Ilib bin/vmctl -c "$TMPDIR/inv.yml" dump pod34; echo "exit=$?"
```
Expected: `error: command not found: bhyve` and `exit=1`.

- [ ] **Step 8: Commit-prep** — leave uncommitted; controller commits.

---

## Self-Review

**Spec coverage:**
- `VM#dump_command` inserting `-o config.dump=1` before the name (after mac) → Task 1.
- `Commands::Dump` (thin, `vm_for`, `executor.capture`, prints; missing-name and unknown-VM raise `CommandError`) → Task 2.
- CLI registration + usage line → Task 2 Step 5.
- Read-only via `capture` (runs even under `-n`) → Task 2 (uses `executor.capture`).
- Error handling (missing name / unknown VM / bhyve failure) → Task 2 tests + the CLI's existing `ExecutorError` rescue.

**Placeholder scan:** None — every step has complete code.

**Type consistency:** `dump_command` (Task 1) is the exact method `Commands::Dump` calls (Task 2). `vm_for`/`capture`/`CommandError`/`COMMANDS` match existing signatures.
