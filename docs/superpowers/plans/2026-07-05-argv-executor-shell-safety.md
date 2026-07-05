# argv-based Executor (shell-safety) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Executor#run`/`capture`/`success?` take argv arrays (no shell) instead of command strings, across all ~14 call sites, closing the shell-injection/mis-parse footgun.

**Architecture:** `Open3.capture3(*argv)` in multi-arg form execs directly — no `/bin/sh`, no word-splitting, no globbing. Interpolation moves inside a single argv element so a value with a space/metacharacter stays one opaque argument. `FakeExecutor` records argv arrays; test assertions become array-based. Hardening only — no behavior change, no new commands, no schema change.

**Tech Stack:** Ruby stdlib (`Open3`), minitest, `FakeExecutor`.

## Global Constraints

- Ruby 4.0 (CI: `ruby -Ilib -Itest test/run_all.rb`). No new gem dependencies.
- Source files keep `# frozen_string_literal: true` + `# lib/vmctl/<path>` headers.
- Tests are minitest under `test/`. Single file: `ruby -Ilib -Itest test/test_x.rb`. Full suite: `ruby -Ilib -Itest test/run_all.rb`.
- Every command is ≥2 tokens, so `Open3.capture3(*argv)` always execs directly (safe). No shell-escape hatch is added.
- Logs/dry-run render `argv.join(' ')` (display only). Error messages use `argv.first`.
- `VM#bhyve_argv` and the supervisor's `Process.spawn(*bhyve_argv)` are already argv — DO NOT change them. `bhyve_command` (`argv.join(' ')` display helper) is unchanged.
- Git commits end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Work on branch `chore/argv-executor`.

---

## Task 1: `Executor` + `FakeExecutor` → argv; migrate `test_executor`; migrate all call sites

**Files:**
- Modify: `lib/vmctl/executor.rb`, `test/test_helper.rb` (FakeExecutor), `test/test_executor.rb`
- Modify (call sites): `lib/vmctl/provisioner.rb`, `lib/vmctl/cloudinit.rb`, `lib/vmctl/netgraph.rb`, `lib/vmctl/vm.rb`, `lib/vmctl/supervisor.rb`, `lib/vmctl/commands/remove_disk.rb`, `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/stop.rb`, `lib/vmctl/commands/destroy.rb`

**Interfaces:**
- Produces: `Executor#run(*argv)`, `#capture(*argv)`, `#success?(*argv)`. `FakeExecutor#run/capture` record argv arrays into `@runs`/`@captures`; `#success?`/canned matching stay substring-matched against `argv.join(' ')`. `capture_unchecked`/`errs:` removed from `FakeExecutor`.

**IMPORTANT — expected partial-red gate:** Flipping `FakeExecutor` to record arrays breaks the `exec.runs`/`captures` string assertions in the command/provisioner/supervisor tests (fixed in Task 2). Task 1's gate is: **`test/test_executor.rb` fully passes**, AND every other full-suite failure is an `exec.runs`/`captures` array-vs-string assertion mismatch in exactly these 9 files — `test_provisioner.rb`, `test_create_command.rb`, `test_add_disk_command.rb`, `test_grow_disk_command.rb`, `test_remove_disk_command.rb`, `test_commands.rb`, `test_supervisor.rb`, `test_destroy_command.rb`, `test_cloudinit.rb`. Report the failing file list and confirm all failures are that shape. Do NOT touch those test files in Task 1.

- [ ] **Step 1: Migrate `test/test_executor.rb` to argv + add safety tests**

Replace `test/test_executor.rb` with:

```ruby
# frozen_string_literal: true
# test/test_executor.rb
require 'test_helper'
require 'vmctl/executor'
require 'tmpdir'

class TestExecutor < Minitest::Test
  def test_capture_returns_stdout
    assert_equal "hello\n", VMCtl::Executor.new.capture('echo', 'hello')
  end

  def test_run_returns_stdout_when_not_dry_run
    assert_equal "hi\n", VMCtl::Executor.new(dry_run: false).run('echo', 'hi')
  end

  def test_run_is_noop_in_dry_run
    e = VMCtl::Executor.new(dry_run: true)
    path = File.join(Dir.tmpdir, "vmctl_dryrun_#{Process.pid}")
    File.delete(path) if File.exist?(path)
    assert_equal "", e.run('touch', path)
    refute File.exist?(path), "dry-run must not execute mutating commands"
  end

  def test_capture_runs_even_in_dry_run
    assert_equal "q\n", VMCtl::Executor.new(dry_run: true).capture('echo', 'q')
  end

  def test_run_raises_on_failure
    assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.run('false') }
  end

  def test_nonzero_exit_message_names_argv_first
    err = assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.capture('false') }
    assert_match(/\Afalse exited with status/, err.message)
  end

  def test_success_is_boolean_and_never_raises
    e = VMCtl::Executor.new
    assert_equal true, e.success?('true')
    assert_equal false, e.success?('false')
  end

  def test_success_returns_false_for_missing_binary
    assert_equal false, VMCtl::Executor.new.success?('vmctl_definitely_missing_binary_xyz', 'arg')
  end

  def test_capture_wraps_missing_binary_as_executor_error
    err = assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.capture('vmctl_definitely_missing_binary_xyz') }
    assert_match(/command not found: vmctl_definitely_missing_binary_xyz/, err.message)
  end

  # Safety property: an argument containing shell metacharacters is passed
  # verbatim and never reaches a shell.
  def test_argv_form_does_not_invoke_a_shell
    Dir.mktmpdir do |dir|
      sentinel = File.join(dir, 'pwned')
      VMCtl::Executor.new.run('echo', "; touch #{sentinel}")
      refute File.exist?(sentinel), 'argv form must not reach a shell'
    end
  end

  # Safety property: a space inside a single argument does not split it.
  def test_single_arg_preserves_spaces
    Dir.mktmpdir do |dir|
      spacey = File.join(dir, 'a b.txt')
      VMCtl::Executor.new.run('touch', spacey)
      assert File.exist?(spacey), 'a space in one arg must not split it into two'
    end
  end
end
```

- [ ] **Step 2: Run the executor tests — they FAIL on the current string API**

Run: `ruby -Ilib -Itest test/test_executor.rb`
Expected: FAIL/ERROR (`wrong number of arguments` — current `run(cmd)` takes one arg).

- [ ] **Step 3: Implement the argv `Executor`**

In `lib/vmctl/executor.rb`, replace `run`, `capture`, `success?`:

```ruby
    # Mutating command. No-op (logs only) in dry-run. argv = separate arguments
    # (never a shell string) so nothing is word-split or shell-interpreted.
    def run(*argv)
      if @dry_run
        VMCtl.logger.info("[dry-run] #{argv.join(' ')}")
        return ""
      end
      capture(*argv)
    end

    # Read-only query. Always executes. Raises on failure.
    def capture(*argv)
      VMCtl.logger.debug("exec: #{argv.join(' ')}")
      stdout, stderr, status = Open3.capture3(*argv)
      unless status.success?
        raise ExecutorError,
              "#{argv.first} exited with status #{status.exitstatus}: #{stderr.strip}"
      end
      stdout
    rescue Errno::ENOENT
      raise ExecutorError, "command not found: #{argv.first}"
    end

    # Probe: true/false by exit status, never raises.
    def success?(*argv)
      VMCtl.logger.debug("probe: #{argv.join(' ')}")
      _out, _err, status = Open3.capture3(*argv)
      status.success?
    rescue SystemCallError
      false
    end
```

(If a `capture_unchecked` method still exists in `executor.rb`, leave it as-is — it was removed in PR #6, so it should be absent; do not re-add it.)

- [ ] **Step 4: Run the executor tests — they PASS**

Run: `ruby -Ilib -Itest test/test_executor.rb`
Expected: PASS (all, including the two safety tests).

- [ ] **Step 5: Update `FakeExecutor` (record argv; drop dead `capture_unchecked`/`errs`)**

In `test/test_helper.rb`, replace the `FakeExecutor` class body with:

```ruby
# Records mutating commands as argv arrays; answers queries/probes from canned
# data keyed by a substring of the joined command. Use in every test that
# touches a shell-out boundary.
class FakeExecutor
  attr_reader :runs, :captures

  # captures: Hash of command-substring => stdout to return from #capture/#run
  # probes:   Hash of command-substring => boolean to return from #success?
  def initialize(captures: {}, probes: {}, dry_run: false)
    @runs = []
    @captures = []
    @canned = captures
    @probes = probes
    @dry_run = dry_run
  end

  def dry_run?
    @dry_run
  end

  def run(*argv)
    @runs << argv
    canned_for(argv) || ""
  end

  def capture(*argv)
    @captures << argv
    canned_for(argv) || ""
  end

  def success?(*argv)
    match = @probes.find { |k, _| argv.join(' ').include?(k) }
    match ? match[1] : true
  end

  private

  def canned_for(argv)
    match = @canned.find { |k, _| argv.join(' ').include?(k) }
    match&.last
  end
end
```

- [ ] **Step 6: Migrate every call site to argv**

Apply these exact edits (interpolation moves inside single elements):

- `lib/vmctl/provisioner.rb:16` → `@exec.run('zfs', 'create', "#{@defaults.zpool}/#{vm.name}")`
- `lib/vmctl/provisioner.rb:21` (create_disk blank) → `@exec.run('truncate', '-s', size, path)`
- `lib/vmctl/provisioner.rb:28` (grow_if_needed) → `@exec.run('truncate', '-s', size, path)`
- `lib/vmctl/provisioner.rb:32` → `@exec.run('cp', image, path)`
- `lib/vmctl/provisioner.rb:46` (grow_disk) → `@exec.run('truncate', '-s', size, path)`
- `lib/vmctl/cloudinit.rb:28` → `@exec.run('makefs', '-t', 'cd9660', '-o', 'rockridge,label=cidata', iso, seeddir)`
- `lib/vmctl/netgraph.rb:14` → `@exec.success?('ngctl', 'info', "#{name}:")`
- `lib/vmctl/vm.rb:97` → `executor.success?('test', '-e', vmm_device)`
- `lib/vmctl/supervisor.rb:30` → `@exec.run('bhyvectl', '--destroy', "--vm=#{@vm.name}")`
- `lib/vmctl/supervisor.rb:75` → `@exec.run('bhyvectl', '--force-poweroff', "--vm=#{@vm.name}") if @bhyve_pid`
- `lib/vmctl/commands/remove_disk.rb:34` → `executor.run('rm', '-f', File.join(vm.dir, disk.file))`
- `lib/vmctl/commands/create.rb:136` → `executor.run('cp', user_data, dest)`
- `lib/vmctl/commands/stop.rb:27` → `executor.run('bhyvectl', '--destroy', "--vm=#{vm.name}") if force`
- `lib/vmctl/commands/stop.rb:38` → `executor.run('bhyvectl', '--destroy', "--vm=#{vm.name}")`
- `lib/vmctl/commands/destroy.rb:18` → `executor.run('zfs', 'destroy', "#{config.defaults.zpool}/#{name}") if opts[:purge]`

Verify none remain: `grep -rnE '\.(run|capture|success\?)\("' lib/` should return nothing (all shell-outs now use argv; `cli.rb`'s `def self.run(argv)` is the CLI entrypoint, not a call site — ignore it).

- [ ] **Step 7: Run the full suite — confirm the expected partial-red shape**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: `test_executor.rb` passes; failures appear ONLY in the 9 listed test files and ONLY as `exec.runs`/`captures` array-vs-string assertion mismatches (Task 2 fixes them). Record the exact failing files/counts and confirm the shape.

- [ ] **Step 8: Commit**

```bash
git add lib/vmctl/executor.rb lib/vmctl/provisioner.rb lib/vmctl/cloudinit.rb lib/vmctl/netgraph.rb lib/vmctl/vm.rb lib/vmctl/supervisor.rb lib/vmctl/commands/remove_disk.rb lib/vmctl/commands/create.rb lib/vmctl/commands/stop.rb lib/vmctl/commands/destroy.rb test/test_helper.rb test/test_executor.rb
git commit -m "$(printf 'feat(executor): argv-based command execution (no shell) + migrate call sites\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 2: Migrate command-test assertions to argv arrays

**Files:**
- Modify: `test/test_provisioner.rb`, `test/test_create_command.rb`, `test/test_add_disk_command.rb`, `test/test_grow_disk_command.rb`, `test/test_remove_disk_command.rb`, `test/test_commands.rb`, `test/test_supervisor.rb`, `test/test_destroy_command.rb`, `test/test_cloudinit.rb`

**Interfaces:** none (test-only). Consumes `FakeExecutor#runs` now holding argv arrays.

- [ ] **Step 1: Update each assertion to the array form**

Apply these exact replacements:

`test/test_provisioner.rb`:
- `assert_includes exec.runs, 'zfs create tank/bhyve/pod35'` → `assert_includes exec.runs, ['zfs', 'create', 'tank/bhyve/pod35']`
- `assert_includes exec.runs, 'truncate -s 100G /bhyve/pod35/pod35-zfs.raw'` → `assert_includes exec.runs, ['truncate', '-s', '100G', '/bhyve/pod35/pod35-zfs.raw']`
- `assert_includes exec.runs, "cp #{img} /bhyve/pod35/pod35-root.raw"` → `assert_includes exec.runs, ['cp', img, '/bhyve/pod35/pod35-root.raw']` (both occurrences)
- `assert_includes exec.runs, 'truncate -s 1M /bhyve/pod35/pod35-root.raw'` → `assert_includes exec.runs, ['truncate', '-s', '1M', '/bhyve/pod35/pod35-root.raw']`
- `refute(exec.runs.any? { |c| c.start_with?('truncate') }, ...)` → `refute(exec.runs.any? { |a| a.first == 'truncate' }, 'no grow when size == source')`
- `assert_includes exec.runs, 'truncate -s 100G /bhyve/pod34/pod34-data.raw'` → `assert_includes exec.runs, ['truncate', '-s', '100G', '/bhyve/pod34/pod34-data.raw']`

`test/test_create_command.rb`:
- `assert_includes exec.runs, 'zfs create tank/bhyve/pod35'` → `assert_includes exec.runs, ['zfs', 'create', 'tank/bhyve/pod35']`
- `assert(exec.runs.any? { |c| c.include?('cp ') && c.include?('pod35-root.raw') })` → `assert(exec.runs.any? { |a| a.first == 'cp' && a.any? { |x| x.include?('pod35-root.raw') } })`
- `assert(exec.runs.any? { |c| c == 'truncate -s 5M ' + File.join(@vm_root, 'pod35', 'pod35-zfs.raw') })` → `assert_includes exec.runs, ['truncate', '-s', '5M', File.join(@vm_root, 'pod35', 'pod35-zfs.raw')]`
- `assert(exec.runs.any? { |c| c.start_with?('makefs ') })` → `assert(exec.runs.any? { |a| a.first == 'makefs' })`

`test/test_add_disk_command.rb`:
- `assert_includes exec.runs, "truncate -s 50G #{File.join(@vm_root, 'pod34', 'pod34-data.raw')}"` → `assert_includes exec.runs, ['truncate', '-s', '50G', File.join(@vm_root, 'pod34', 'pod34-data.raw')]`
- `assert(exec.runs.any? { |c| c.include?('cp ') && c.include?('gold.raw') })` → `assert(exec.runs.any? { |a| a.first == 'cp' && a.any? { |x| x.include?('gold.raw') } })`

`test/test_grow_disk_command.rb`:
- `assert_includes exec.runs, "truncate -s 100G #{File.join(@vm_root, 'pod34', 'pod34-data.raw')}"` → `assert_includes exec.runs, ['truncate', '-s', '100G', File.join(@vm_root, 'pod34', 'pod34-data.raw')]`

`test/test_remove_disk_command.rb`:
- `refute(exec.runs.any? { |c| c.start_with?('rm ') })` → `refute(exec.runs.any? { |a| a.first == 'rm' })`
- `assert_includes exec.runs, "rm -f #{File.join(@vm_root, 'pod34', 'pod34-data.raw')}"` → `assert_includes exec.runs, ['rm', '-f', File.join(@vm_root, 'pod34', 'pod34-data.raw')]`

`test/test_commands.rb`:
- `assert_includes exec.runs, 'bhyvectl --destroy --vm=pod34'` → `assert_includes exec.runs, ['bhyvectl', '--destroy', '--vm=pod34']`
- (`assert_empty exec.runs, "no destroy without --force"` — unchanged; an empty array is still empty.)

`test/test_supervisor.rb`:
- `destroys = exec.runs.select { |c| c.include?('bhyvectl --destroy') }` → `destroys = exec.runs.select { |a| a.first == 'bhyvectl' && a[1] == '--destroy' }`
- `assert_equal 1, exec.runs.count { |c| c.include?('bhyvectl --destroy --vm=pod34') }` → `assert_equal 1, exec.runs.count { |a| a == ['bhyvectl', '--destroy', '--vm=pod34'] }`
- `assert_equal 1, exec.runs.count { |c| c.include?('bhyvectl --destroy') }` → `assert_equal 1, exec.runs.count { |a| a.first == 'bhyvectl' && a[1] == '--destroy' }`

`test/test_destroy_command.rb`:
- `refute(exec.runs.any? { |c| c.start_with?('zfs destroy') }, ...)` → `refute(exec.runs.any? { |a| a.first == 'zfs' && a[1] == 'destroy' }, 'no purge without --purge')`
- `assert_includes exec.runs, 'zfs destroy tank/bhyve/pod35'` → `assert_includes exec.runs, ['zfs', 'destroy', 'tank/bhyve/pod35']`

`test/test_cloudinit.rb` (replace the find + regex assert):
```ruby
    cmd = exec.runs.find { |a| a.first == 'makefs' }
    refute_nil cmd, 'makefs must run'
    assert_includes cmd, expected_iso
```

- [ ] **Step 2: Run the full suite — GREEN**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all tests pass, 0 failures.

- [ ] **Step 3: Confirm no string call sites or string assertions remain**

Run: `grep -rnE '\.(run|capture|success\?)\("' lib/ ; grep -rn "exec.runs, '" test/ ; grep -rn 'exec.runs, "' test/`
Expected: no output (all argv). (`cli.rb`'s `def self.run(argv)` is not matched by the pattern.)

- [ ] **Step 4: Commit**

```bash
git add test/test_provisioner.rb test/test_create_command.rb test/test_add_disk_command.rb test/test_grow_disk_command.rb test/test_remove_disk_command.rb test/test_commands.rb test/test_supervisor.rb test/test_destroy_command.rb test/test_cloudinit.rb
git commit -m "$(printf 'test: assert on argv arrays for executor call sites\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] Full suite: `ruby -Ilib -Itest test/run_all.rb` → all PASS.
- [ ] `grep -rnE '\.(run|capture|success\?)\("' lib/` → empty (no string shell-outs remain).
- [ ] `git log --oneline` shows the 2 task commits on `chore/argv-executor`.

## Notes for the implementer

- The safety property is proven by `test_executor.rb`'s `test_argv_form_does_not_invoke_a_shell` and `test_single_arg_preserves_spaces` — do not weaken them.
- Only `exec.runs`/`captures` *assertions* change in Task 2; probe/canned *setup* (`probes: { ... }`, `captures: { ... }`) stays substring-keyed and is untouched.
- `test_netgraph.rb`, `test_add_nic_command.rb`, and status/console tests use only `success?` probes — they need no changes in either task.
