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
          state = vm.running?(executor) ? 'running' : 'stopped'
          pid = vm.read_pid
          pid_str = pid ? " pid #{pid}" : ''
          puts "#{vm.name}: #{state}#{pid_str} (#{vm.entry.network} link #{vm.entry.link})"
        end
      end
    end
  end
end
