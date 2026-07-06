# Stale-vmm Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a stale vmm device (present but no live supervisor) and surface it: `VM#stale?`, a third `stale` state in `status`, and an actionable `start` error instead of "already running".

**Architecture:** `VM#supervisor_alive?` probes the pidfile's pid via `executor.success?('kill','-0',pid)`; `VM#stale?` = `running?` && !`supervisor_alive?`. `status` and `start` consume these.

**Tech Stack:** Ruby stdlib, minitest, `FakeExecutor`.

## Global Constraints

- Ruby 4.0 (CI: `ruby -Ilib -Itest test/run_all.rb`). No new gems.
- Source files keep `# frozen_string_literal: true` + `# lib/vmctl/<path>` headers.
- Tests are minitest, `FakeExecutor` at the shell-out boundary. `FakeExecutor#success?` returns `true` for UNSPECIFIED probes and matches a probe key as a substring of `argv.join(' ')` — so set `'kill -0 <pid>' => true/false` and `'/dev/vmm/<name>' => true/false` explicitly.
- `read_pid` reads `<run_dir>/<name>.pid`; tests that need a pidfile write it into a temp `run_dir`.
- User-facing errors are `VMCtl::Commands::CommandError`.
- Git commits end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Branch `feat/stale-vmm-detection`.

---

## Task 1: `VM#supervisor_alive?` + `VM#stale?`

**Files:**
- Modify: `lib/vmctl/vm.rb`
- Test: `test/test_vm.rb`

**Interfaces:**
- Produces: `VM#supervisor_alive?(executor)` → true iff the pidfile exists and its pid is a live process (`kill -0`). `VM#stale?(executor)` → `running?(executor) && !supervisor_alive?(executor)`.

- [ ] **Step 1: Write the failing tests** — add to `test/test_vm.rb`. First extend the `defaults` helper with a `run_dir:` kwarg (default keeps the current value):

```ruby
  def defaults(config_dir: '/bhyve/configs', run_dir: '/var/run/vmctl')
    VMCtl::Defaults.new(
      config_dir: config_dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10,
      run_dir: run_dir, log_dir: '/var/log/vmctl'
    )
  end
```

Then the tests:

```ruby
  def test_supervisor_alive_true_when_pid_running
    Dir.mktmpdir do |run|
      File.write(File.join(run, 'pod34.pid'), '4242')
      vm = VMCtl::VM.new(entry, defaults(run_dir: run))
      exec = FakeExecutor.new(probes: { 'kill -0 4242' => true })
      assert vm.supervisor_alive?(exec)
    end
  end

  def test_supervisor_alive_false_when_no_pidfile
    Dir.mktmpdir do |run|
      vm = VMCtl::VM.new(entry, defaults(run_dir: run))
      refute vm.supervisor_alive?(FakeExecutor.new)
    end
  end

  def test_supervisor_alive_false_when_pid_dead
    Dir.mktmpdir do |run|
      File.write(File.join(run, 'pod34.pid'), '4242')
      vm = VMCtl::VM.new(entry, defaults(run_dir: run))
      exec = FakeExecutor.new(probes: { 'kill -0 4242' => false })
      refute vm.supervisor_alive?(exec)
    end
  end

  def test_stale_true_when_vmm_but_no_live_supervisor
    Dir.mktmpdir do |run|
      vm = VMCtl::VM.new(entry, defaults(run_dir: run))   # no pidfile
      exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
      assert vm.stale?(exec)
    end
  end

  def test_stale_false_when_running_with_live_supervisor
    Dir.mktmpdir do |run|
      File.write(File.join(run, 'pod34.pid'), '4242')
      vm = VMCtl::VM.new(entry, defaults(run_dir: run))
      exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'kill -0 4242' => true })
      refute vm.stale?(exec)
    end
  end

  def test_stale_false_when_no_vmm_device
    Dir.mktmpdir do |run|
      vm = VMCtl::VM.new(entry, defaults(run_dir: run))
      exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
      refute vm.stale?(exec)
    end
  end
```

(`test_vm.rb` already requires `tmpdir`. `entry` builds a `pod34` VM.)

- [ ] **Step 2: Run — FAIL**

Run: `ruby -Ilib -Itest test/test_vm.rb -n test_stale_true_when_vmm_but_no_live_supervisor`
Expected: FAIL (`undefined method 'stale?'`).

- [ ] **Step 3: Implement** — in `lib/vmctl/vm.rb`, add after `running?`:

```ruby
    # A live supervisor: a pidfile whose pid is an existing process.
    def supervisor_alive?(executor)
      pid = read_pid
      !!pid && executor.success?('kill', '-0', pid.to_s)
    end

    # The vmm device exists but nothing is supervising it (bhyve died without
    # its supervisor running `bhyvectl --destroy`).
    def stale?(executor)
      running?(executor) && !supervisor_alive?(executor)
    end
```

- [ ] **Step 4: Run — PASS**

Run: `ruby -Ilib -Itest test/test_vm.rb && ruby -Ilib -Itest test/run_all.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/vm.rb test/test_vm.rb
git commit -m "$(printf 'feat(vm): supervisor_alive? + stale? (vmm device without a live supervisor)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 2: `status` third state + `start` stale error

**Files:**
- Modify: `lib/vmctl/commands/status.rb`, `lib/vmctl/commands/start.rb`
- Test: `test/test_commands.rb`

**Interfaces:**
- Consumes: `VM#running?`, `VM#supervisor_alive?`, `VM#stale?`, `VM#read_pid`.
- Produces: `status` prints `running`/`stale`/`stopped`; `start` raises a stale-device error (with the `stop --force` hint) for a stale VM.

- [ ] **Step 1: Update/add the tests in `test/test_commands.rb`**

In `TestStatusCommand`, **replace** `test_status_reports_running_when_vmm_device_present` (it must now set up a live supervisor) and add a stale test. `CmdTestSupport#run_dir` is a temp dir; write the pidfile there.

```ruby
  def test_status_reports_running_when_vmm_and_live_supervisor
    File.write(File.join(run_dir, 'pod34.pid'), '4242')
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'kill -0 4242' => true })
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/running/, out)
    assert_match(/pid 4242/, out)
  end

  def test_status_reports_stale_when_vmm_but_no_live_supervisor
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })  # no pidfile -> stale
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/stale/, out)
    assert_match(/stop --force pod34/, out)
    refute_match(/running/, out)
  end
```

(`test_status_reports_stopped_when_no_vmm_device` stays as-is: `/dev/vmm/pod34 => false` → `stopped`.)

In `TestStartCommand`, **replace** `test_start_refuses_when_already_running` to set up a live supervisor, and add a stale test:

```ruby
  def test_start_refuses_when_already_running
    File.write(File.join(run_dir, 'pod34.pid'), '4242')
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'kill -0 4242' => true })
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/already running/, err.message)
  end

  def test_start_reports_stale_vmm_device
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })  # no pidfile -> stale
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/stale vmm device/, err.message)
    assert_match(/stop --force pod34/, err.message)
  end
```

- [ ] **Step 2: Run — FAIL**

Run: `ruby -Ilib -Itest test/test_commands.rb -n test_status_reports_stale_when_vmm_but_no_live_supervisor`
Expected: FAIL (status prints `running`, not `stale`).

- [ ] **Step 3: Implement**

Replace the `vms.each` body in `lib/vmctl/commands/status.rb#call`:

```ruby
        vms.each do |vm|
          net = "(#{vm.entry.network} link #{vm.entry.link})"
          if !vm.running?(executor)
            puts "#{vm.name}: stopped #{net}"
          elsif vm.supervisor_alive?(executor)
            puts "#{vm.name}: running pid #{vm.read_pid} #{net}"
          else
            puts "#{vm.name}: stale — vmm device with no live supervisor; " \
                 "run 'vmctl stop --force #{vm.name}' #{net}"
          end
        end
```

In `lib/vmctl/commands/start.rb#start_one`, replace the running check:

```ruby
        if vm.running?(executor)
          if vm.stale?(executor)
            raise CommandError,
                  "#{vm.name} has a stale vmm device — run 'vmctl stop --force #{vm.name}' first"
          end
          raise CommandError, "#{vm.name} already running"
        end
```

- [ ] **Step 4: Run — PASS**

Run: `ruby -Ilib -Itest test/test_commands.rb && ruby -Ilib -Itest test/run_all.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/status.rb lib/vmctl/commands/start.rb test/test_commands.rb
git commit -m "$(printf 'feat: status stale state + actionable start error for a stale vmm device\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] Full suite: `ruby -Ilib -Itest test/run_all.rb` → all PASS.
- [ ] `git log --oneline` shows the 2 task commits on `feat/stale-vmm-detection`.

## Notes for the implementer

- `status` evaluates `running?` first, then `supervisor_alive?` only when running — a stopped VM does no `kill -0` probe.
- The stale line intentionally omits `pid N` (the pidfile pid is dead); `running` shows it.
- `start` raises before the nic-cap/bridge/write_config steps, so the stale/already-running tests need no bridge probe.
