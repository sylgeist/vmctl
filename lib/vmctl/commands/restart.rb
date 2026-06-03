# frozen_string_literal: true
# lib/vmctl/commands/restart.rb
require_relative 'base'
require_relative 'stop'
require_relative 'start'

module VMCtl
  module Commands
    class Restart < Base
      STOP_TIMEOUT = 30 # seconds to wait for a graceful stop
      POLL_INTERVAL = 0.5

      def call(args)
        name = args.first
        raise CommandError, 'restart requires a VM name' unless name
        vm = vm_for(name)
        Stop.new(config: config, executor: executor).call([name])
        wait_until_stopped(vm) unless executor.dry_run?
        Start.new(config: config, executor: executor).call([name])
      end

      private

      def wait_until_stopped(vm)
        deadline = clock + STOP_TIMEOUT
        while vm.running?(executor)
          if clock >= deadline
            raise CommandError, "#{vm.name} did not stop within #{STOP_TIMEOUT}s"
          end
          sleep POLL_INTERVAL
        end
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
