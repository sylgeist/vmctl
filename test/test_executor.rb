# frozen_string_literal: true
# test/test_executor.rb
require 'test_helper'
require 'vmctl/executor'
require 'tmpdir'

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

  def test_success_returns_false_for_missing_binary
    e = VMCtl::Executor.new
    # A no-metacharacter command is exec'd directly; a missing binary must not raise.
    assert_equal false, e.success?("vmctl_definitely_missing_binary_xyz arg")
  end

  def test_capture_wraps_missing_binary_as_executor_error
    e = VMCtl::Executor.new
    err = assert_raises(VMCtl::ExecutorError) { e.capture("vmctl_definitely_missing_binary_xyz") }
    assert_match(/command not found/, err.message)
  end

  def test_capture_unchecked_returns_stdout_on_nonzero_exit
    e = VMCtl::Executor.new
    # Models a command (like bhyve config.dump) that writes stdout then exits non-zero.
    out, err, status = e.capture_unchecked("sh -c 'printf hi; exit 1'")
    assert_equal 'hi', out
    assert_equal '', err
    assert_equal 1, status
  end

  def test_capture_unchecked_returns_stderr
    e = VMCtl::Executor.new
    out, err, status = e.capture_unchecked("sh -c 'printf boom >&2; exit 2'")
    assert_equal '', out
    assert_equal 'boom', err
    assert_equal 2, status
  end

  def test_capture_unchecked_wraps_missing_binary
    e = VMCtl::Executor.new
    assert_raises(VMCtl::ExecutorError) { e.capture_unchecked("vmctl_definitely_missing_binary_xyz") }
  end
end
