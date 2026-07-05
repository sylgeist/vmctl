# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'vmctl/log'

# Keep test output pristine; tests assert on behavior, not log lines.
VMCtl.log_level = Logger::FATAL

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
