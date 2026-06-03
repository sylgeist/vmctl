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
