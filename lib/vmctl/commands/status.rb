# frozen_string_literal: true
# lib/vmctl/commands/status.rb
require_relative 'base'

module VMCtl
  module Commands
    class Status < Base
      def call(args)
        all = args.delete('--all')
        vms = targets(args, all: all || args.empty?)
        vms.each do |vm|
          running = executor.success?("test -e #{vm.vmm_device}")
          state = running ? 'running' : 'stopped'
          pid = read_pid(vm)
          pid_str = pid ? " pid #{pid}" : ''
          puts "#{vm.name}: #{state}#{pid_str} (#{vm.entry.network} link #{vm.entry.link})"
        end
      end

      private

      def read_pid(vm)
        return nil unless File.exist?(vm.pidfile)
        File.read(vm.pidfile).strip
      rescue StandardError
        nil
      end
    end
  end
end
