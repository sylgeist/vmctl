# frozen_string_literal: true
# test/test_cli.rb
require 'test_helper'
require 'stringio'
require 'tempfile'
require 'vmctl/cli'

class TestCLI < Minitest::Test
  def capture_exit
    out = StringIO.new
    $stdout = out
    code = nil
    begin
      yield
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = STDOUT
    end
    [code, out.string]
  end

  def test_version_flag_prints_and_exits_zero
    code, out = capture_exit { VMCtl::CLI.run(['--version']) }
    assert_equal 0, code
    assert_match(/vmctl #{VMCtl::VERSION}/, out)
  end

  def test_help_prints_usage
    code, out = capture_exit { VMCtl::CLI.run(['help']) }
    assert_equal 0, code
    assert_match(/Usage: vmctl/, out)
  end

  def test_unknown_command_exits_two
    code, _ = capture_exit do
      $stderr = StringIO.new
      begin
        VMCtl::CLI.run(['frobnicate'])
      ensure
        $stderr = STDERR
      end
    end
    assert_equal 2, code
  end

  def test_no_command_prints_usage_exits_two
    code, _ = capture_exit do
      $stderr = StringIO.new
      begin
        VMCtl::CLI.run([])
      ensure
        $stderr = STDERR
      end
    end
    assert_equal 2, code
  end

  def test_subcommand_bad_flag_exits_two
    inv = Tempfile.new(['inv', '.yml'])
    inv.write("vms: {}\n")
    inv.flush
    code, _ = capture_exit do
      $stderr = StringIO.new
      begin
        VMCtl::CLI.run(['-c', inv.path, 'stop', '--bogus'])
      ensure
        $stderr = STDERR
      end
    end
    assert_equal 2, code
  end

  def test_info_verb_registered
    assert_equal VMCtl::Commands::Info, VMCtl::CLI::COMMANDS['info']
    assert_match(/^\s+info /, VMCtl::CLI::USAGE)
  end
end
