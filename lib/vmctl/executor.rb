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
    rescue Errno::ENOENT
      # A no-metacharacter command string is exec'd directly (no shell), so a
      # missing binary surfaces as ENOENT — report it as an ExecutorError.
      raise ExecutorError, "command not found: #{cmd.split.first}"
    end

    # Run a command and return [stdout, stderr, exitstatus] WITHOUT raising on a
    # non-zero exit. For commands that exit non-zero by design — e.g. bhyve with
    # config.dump=1, which prints the resolved config to stdout and exits 1.
    def capture_unchecked(cmd)
      VMCtl.logger.debug("exec (unchecked): #{cmd}")
      stdout, stderr, status = Open3.capture3(cmd)
      [stdout, stderr, status.exitstatus]
    rescue Errno::ENOENT
      raise ExecutorError, "command not found: #{cmd.split.first}"
    end

    # Probe: true/false by exit status, never raises.
    def success?(cmd)
      VMCtl.logger.debug("probe: #{cmd}")
      _out, _err, status = Open3.capture3(cmd)
      status.success?
    rescue SystemCallError
      # Missing binary / unrunnable command counts as "not successful".
      false
    end
  end
end
