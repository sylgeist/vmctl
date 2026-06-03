# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'vmctl/log'

# Keep test output pristine; tests assert on behavior, not log lines.
VMCtl.log_level = Logger::FATAL

# Records mutating commands, answers queries/probes from canned data.
# Use in every test that touches a shell-out boundary.
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

  def run(cmd)
    @runs << cmd
    canned_for(cmd) || ""
  end

  def capture(cmd)
    @captures << cmd
    canned_for(cmd) || ""
  end

  def success?(cmd)
    match = @probes.find { |k, _| cmd.include?(k) }
    match ? match[1] : true
  end

  private

  def canned_for(cmd)
    match = @canned.find { |k, _| cmd.include?(k) }
    match&.last
  end
end
