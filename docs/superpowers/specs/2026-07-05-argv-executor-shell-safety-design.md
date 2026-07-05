# vmctl argv-based Executor (shell-safety) — Design

**Date:** 2026-07-05
**Status:** Approved design, pre-implementation
**Builds on:** Phases 1–4 on `main` (through multi-NIC, PR #7).

## Summary

Make `Executor` — vmctl's single shell-out boundary — take commands as **argv
arrays (separate arguments)** instead of pre-built strings. Ruby's multi-argument
`Open3.capture3(*argv)` execs the program **directly, with no shell**: no
`/bin/sh -c`, no word-splitting, no globbing. This removes the shell-injection /
mis-parse footgun that exists today because every helper shell-out interpolates
operator-controlled values (VM name, paths, bridge, iso, size) into a command
string.

This is a hardening refactor: no behavior change beyond safety, no new commands,
no inventory/schema change. It aligns the helper shell-outs with the boot path,
which already builds an argv (`VM#bhyve_argv`) and spawns it via
`Process.spawn(*argv)`.

## Background / motivation

`Executor#run`/`#capture`/`#success?` currently accept one `cmd` string and pass
it to `Open3.capture3(cmd)`. With a single string, Ruby routes through
`/bin/sh -c` when the string contains shell metacharacters. The code acknowledges
the trade-off in a comment (`# … callers own injection safety`). A VM named
`foo; reboot`, or a path containing a space, would break the command or (worst
case) inject a second command. The threat is a footgun more than a remote vuln
(inputs come from the root operator's own inventory/CLI), but it is real, and the
interpolation surface grew with the disk and NIC features.

The Ruby-community-standard fix is the argv form: pass the command and each
argument as separate arguments so nothing is ever shell-interpreted. Stdlib
`Open3`/`Process.spawn` provide it directly (the popular `TTY::Command` /
`mixlib-shellout` gems wrap the same mechanism; vmctl stays stdlib-only).

## `Executor` API (`lib/vmctl/executor.rb`)

`run`, `capture`, and `success?` take a **splat argv**:

```ruby
def run(*argv)
  if @dry_run
    VMCtl.logger.info("[dry-run] #{argv.join(' ')}")
    return ""
  end
  capture(*argv)
end

def capture(*argv)
  VMCtl.logger.debug("exec: #{argv.join(' ')}")
  stdout, stderr, status = Open3.capture3(*argv)   # multi-arg => no shell
  unless status.success?
    raise ExecutorError,
          "#{argv.first} exited with status #{status.exitstatus}: #{stderr.strip}"
  end
  stdout
rescue Errno::ENOENT
  raise ExecutorError, "command not found: #{argv.first}"
end

def success?(*argv)
  VMCtl.logger.debug("probe: #{argv.join(' ')}")
  _out, _err, status = Open3.capture3(*argv)
  status.success?
rescue SystemCallError
  false
end
```

- Every command is ≥2 tokens, so `Open3.capture3(*argv)` always execs directly.
- Logs and the dry-run line render `argv.join(' ')` for readability — a **display
  string only**; the array is what executes. (`argv.first` replaces the old
  `cmd.split.first` in error messages.)
- **No "reject strings with spaces" guard.** A single argument *may* legitimately
  contain a space (a path like `/bhyve/my vm/x.raw` is one element — exactly what
  this change enables). The array-recording tests (below) are the regression net
  instead.

## Call-site migration

Each interpolated-string shell-out becomes an argv array; interpolation moves
*inside* a single element so a value with a space/metacharacter stays one opaque
argument. Full inventory (14 sites):

| File:line | Before | After |
|---|---|---|
| `provisioner.rb:16` | `run("zfs create #{zpool}/#{vm.name}")` | `run('zfs', 'create', "#{zpool}/#{vm.name}")` |
| `provisioner.rb:21,28,46` | `run("truncate -s #{size} #{path}")` | `run('truncate', '-s', size, path)` |
| `provisioner.rb:32` | `run("cp #{image} #{path}")` | `run('cp', image, path)` |
| `cloudinit.rb:28` | `run("makefs -t cd9660 -o rockridge,label=cidata #{iso} #{seeddir}")` | `run('makefs', '-t', 'cd9660', '-o', 'rockridge,label=cidata', iso, seeddir)` |
| `netgraph.rb:14` | `success?("ngctl info #{name}:")` | `success?('ngctl', 'info', "#{name}:")` |
| `vm.rb:97` | `success?("test -e #{vmm_device}")` | `success?('test', '-e', vmm_device)` |
| `supervisor.rb:30` | `run("bhyvectl --destroy --vm=#{@vm.name}")` | `run('bhyvectl', '--destroy', "--vm=#{@vm.name}")` |
| `supervisor.rb:75` | `run("bhyvectl --force-poweroff --vm=#{@vm.name}")` | `run('bhyvectl', '--force-poweroff', "--vm=#{@vm.name}")` |
| `remove_disk.rb:34` | `run("rm -f #{File.join(vm.dir, disk.file)}")` | `run('rm', '-f', File.join(vm.dir, disk.file))` |
| `create.rb:136` | `run("cp #{user_data} #{dest}")` | `run('cp', user_data, dest)` |
| `stop.rb:27,38` | `run("bhyvectl --destroy --vm=#{vm.name}")` | `run('bhyvectl', '--destroy', "--vm=#{vm.name}")` |
| `destroy.rb:18` | `run("zfs destroy #{zpool}/#{name}")` | `run('zfs', 'destroy', "#{zpool}/#{name}")` |

`VM#bhyve_argv` and the supervisor's `Process.spawn(*bhyve_argv)` are already argv
— untouched. `bhyve_command` (the `argv.join(' ')` display helper used for logging
and the dry-run print) is unchanged.

## `FakeExecutor` + tests (`test/test_helper.rb`)

- `run(*argv)` / `capture(*argv)` record the **argv array** into `@runs`/
  `@captures`. `success?(*argv)` unchanged in spirit.
- **Canned-response and probe keys stay substrings**, matched against
  `argv.join(' ')`. So test *setup* (`probes: { 'ngctl info labs_vlan50:' => true }`,
  `captures: { … }`) is unchanged — only the `exec.runs`/`captures` *assertions*
  become array-based.
- **Remove the now-dead `capture_unchecked` and the `errs:` param** from
  `FakeExecutor` (orphaned when `dump` stopped shelling out in PR #6; no test
  references them). This keeps the fake in step with the real `Executor` (which
  has no `capture_unchecked`).

```ruby
class FakeExecutor
  attr_reader :runs, :captures
  def initialize(captures: {}, probes: {}, dry_run: false)
    @runs = []; @captures = []; @canned = captures; @probes = probes; @dry_run = dry_run
  end
  def dry_run?; @dry_run; end
  def run(*argv);     @runs << argv;     canned_for(argv) || ""; end
  def capture(*argv); @captures << argv; canned_for(argv) || ""; end
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

Assertions across the command/provisioner/supervisor tests migrate to arrays,
e.g.:

```ruby
assert_includes exec.runs, ['zfs', 'create', 'tank/bhyve/pod35']
assert(exec.runs.any? { |a| a.first == 'cp' && a.include?(path) })
assert_includes exec.runs, ['truncate', '-s', '5M', File.join(@vm_root, 'pod35', 'pod35-zfs.raw')]
assert_includes exec.runs, ['bhyvectl', '--destroy', '--vm=pod34']
```

Test files needing assertion updates (those asserting on `exec.runs`/`captures`):
`test_provisioner.rb`, `test_create_command.rb`, `test_add_disk_command.rb`,
`test_grow_disk_command.rb`, `test_remove_disk_command.rb`, `test_commands.rb`
(stop/restart), `test_supervisor.rb`, `test_destroy_command.rb`,
`test_cloudinit.rb`. Files using only `success?` probes (`test_netgraph.rb`,
`test_add_nic_command.rb`, status/console paths) need **no** change — probe setup
is untouched.

## `Executor` unit tests (`test/test_executor.rb`)

Migrate the existing string-command tests to argv form (`capture('echo', 'hi')`),
and add the safety-property tests that justify the change — using a **real**
`Executor` against harmless commands:

```ruby
def test_argv_form_does_not_invoke_a_shell
  Dir.mktmpdir do |dir|
    sentinel = File.join(dir, 'pwned')
    # If argv were shell-joined, "; touch <sentinel>" would run. As one arg to
    # echo, it is printed literally and no file is created.
    VMCtl::Executor.new.run('echo', "; touch #{sentinel}")
    refute File.exist?(sentinel), 'argv form must not reach a shell'
  end
end

def test_single_arg_preserves_spaces
  Dir.mktmpdir do |dir|
    spacey = File.join(dir, 'a b.txt')
    VMCtl::Executor.new.run('touch', spacey)
    assert File.exist?(spacey), 'a space in one arg must not split it into two'
  end
end

def test_missing_binary_reports_command_not_found
  err = assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.run('vmctl-no-such-bin') }
  assert_match(/command not found: vmctl-no-such-bin/, err.message)
end

def test_nonzero_exit_raises_with_argv_first
  err = assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.capture('false') }
  assert_match(/\Afalse exited with status/, err.message)
end
```

(`echo`, `touch`, `false` are POSIX built-ins/binaries available in CI.)

## Error handling

Unchanged semantics: non-zero exit → `ExecutorError` (message now
`"#{argv.first} exited …"`); missing binary → `ExecutorError`
(`"command not found: #{argv.first}"`); `success?` swallows failures to `false`.
The only surface change is that error messages name `argv.first` instead of the
first whitespace-split token — identical output for the current commands.

## Out of scope (YAGNI)

- No shell-requiring commands exist today (no pipes/redirects/globs), so **no
  shell-escape hatch** is added. If one is ever needed, it would be an explicit,
  separate `run_shell`-style method — not the default path.
- No timeouts / streaming / retries (what `TTY::Command`/`mixlib-shellout` add) —
  not needed, and would pull in scope.
- No change to `VM#bhyve_argv` / supervisor spawn (already argv-safe).
- No gem dependency (vmctl stays stdlib-only).
