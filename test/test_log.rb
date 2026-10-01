# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'
require 'stringio'

# vmctl is stdlib-only: Ruby 4 moved `logger` out of the default gems, and
# FreeBSD's quarterly packages have no gems for ruby40 (labs skylab, 2026-10-01).
class TestLog < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  def capture(level)
    io = StringIO.new
    log = VMCtl::Log.new(io, progname: 'vmctl')
    log.level = level
    yield log
    io.string
  end

  def test_does_not_require_the_logger_gem
    refute_match(/require ['"]logger['"]/, File.read(File.join(LIB, 'vmctl/log.rb')))
  end

  def test_loads_with_gems_disabled
    out, err, st = Open3.capture3(RbConfig.ruby, '--disable=gems', "-I#{LIB}", '-e',
                                  'require "vmctl/log"; VMCtl.log_level = VMCtl::Log::INFO; VMCtl.logger.info("hi")')
    assert st.success?, err
    assert_equal "[INFO] vmctl: hi\n", err
    assert_equal '', out
  end

  def test_format_and_vm_tag
    s = capture(VMCtl::Log::INFO) do |l|
      l.info('plain')
      Thread.current[:vmctl_vm] = 'nbtest'
      l.info('tagged')
    ensure
      Thread.current[:vmctl_vm] = nil
    end
    assert_equal "[INFO] vmctl: plain\n[INFO] vmctl[nbtest]: tagged\n", s
  end

  def test_level_filters
    s = capture(VMCtl::Log::INFO) { |l| l.debug('hidden'); l.warn('shown') }
    assert_equal "[WARN] vmctl: shown\n", s
    assert_equal '', capture(VMCtl::Log::FATAL) { |l| l.error('quiet') }
  end
end
