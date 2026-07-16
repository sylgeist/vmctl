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

  def test_pipe_passes_stdout_through
    # echo hi | cat  ->  "hi\n"
    assert_equal "hi\n", VMCtl::Executor.new.pipe(['echo', 'hi'], ['cat'])
  end

  def test_pipe_raises_when_a_stage_fails
    assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.pipe(['echo', 'hi'], ['false']) }
  end

  def test_pipe_raises_when_first_stage_fails
    assert_raises(VMCtl::ExecutorError) { VMCtl::Executor.new.pipe(['false'], ['cat']) }
  end

  def test_pipe_is_noop_in_dry_run
    assert_equal "", VMCtl::Executor.new(dry_run: true).pipe(['echo', 'hi'], ['cat'])
  end
end
