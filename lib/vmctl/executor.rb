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

    # Mutating command. No-op (logs only) in dry-run.
    def run(cmd)
      if @dry_run
        VMCtl.logger.info("[dry-run] #{cmd}")
        return ""
      end
      capture(cmd)
    end

    # Read-only query. Always executes. Raises on failure.
    def capture(cmd)
      VMCtl.logger.debug("exec: #{cmd}")
      # Intentional: commands are pre-built strings; callers own injection safety.
      stdout, stderr, status = Open3.capture3(cmd)
      unless status.success?
        raise ExecutorError,
              "#{cmd.split.first} exited with status #{status.exitstatus}: #{stderr.strip}"
      end
      stdout
    end

    # Probe: true/false by exit status, never raises.
    def success?(cmd)
      VMCtl.logger.debug("probe: #{cmd}")
      _out, _err, status = Open3.capture3(cmd)
      status.success?
    end
  end
end
