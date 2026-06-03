# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'vmctl/log'

# Keep test output pristine; tests assert on behavior, not log lines.
VMCtl.log_level = Logger::FATAL
