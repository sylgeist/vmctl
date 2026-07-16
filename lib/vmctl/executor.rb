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
      # Missing binary / unrunnable command counts as "not successful".
      false
    end

    # Run argv1 | argv2 with no shell. Returns argv2's stdout. Raises on any
    # non-zero stage. No-op (logs only) in dry-run, returning "".
    def pipe(argv1, argv2)
      if @dry_run
        VMCtl.logger.info("[dry-run] #{argv1.join(' ')} | #{argv2.join(' ')}")
        return ""
      end
      VMCtl.logger.debug("exec: #{argv1.join(' ')} | #{argv2.join(' ')}")
      out, statuses = Open3.pipeline_r(argv1, argv2) { |o, ts| [o.read, ts.map(&:value)] }
      statuses.each_with_index do |status, i|
        next if status.success?
        argv = i.zero? ? argv1 : argv2
        raise ExecutorError, "#{argv.first} exited with status #{status.exitstatus} in pipeline"
      end
      out
    rescue Errno::ENOENT => e
      raise ExecutorError, "command not found in pipeline: #{e.message}"
    end
  end
end
