# frozen_string_literal: true
# lib/vmctl/executor.rb
require 'open3'
require_relative 'log'

module VMCtl
  class ExecutorError < StandardError; end

  # The sole shell-out boundary. Inject a fake in tests.
  class Executor
    def initialize(dry_run: false)
      @dry_run = dry_run
    end

    def dry_run?
      @dry_run
    end

    # Mutating command. No-op (logs only) in dry-run. argv = separate arguments
    # (never a shell string) so nothing is word-split or shell-interpreted.
    def run(*argv)
      if @dry_run
        VMCtl.logger.info("[dry-run] #{argv.join(' ')}")
        return ""
      end
      capture(*argv)
    end

    # Read-only query. Always executes. Raises on failure.
    def capture(*argv)
      VMCtl.logger.debug("exec: #{argv.join(' ')}")
      stdout, stderr, status = Open3.capture3(*argv)
      unless status.success?
        raise ExecutorError,
              "#{argv.first} exited with status #{status.exitstatus}: #{stderr.strip}"
      end
      stdout
    rescue Errno::ENOENT
      raise ExecutorError, "command not found: #{argv.first}"
    end

    # Probe: true/false by exit status, never raises.
    def success?(*argv)
      VMCtl.logger.debug("probe: #{argv.join(' ')}")
      _out, _err, status = Open3.capture3(*argv)
      status.success?
    rescue SystemCallError
      false
    end
  end
end
