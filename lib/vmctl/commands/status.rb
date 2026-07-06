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
          net = "(#{vm.entry.network} link #{vm.entry.link})"
          if !vm.running?(executor)
            puts "#{vm.name}: stopped #{net}"
          elsif vm.supervisor_alive?(executor)
            puts "#{vm.name}: running pid #{vm.read_pid} #{net}"
          else
            puts "#{vm.name}: stale — vmm device with no live supervisor; " \
                 "run 'vmctl stop --force #{vm.name}' #{net}"
          end
        end
      end
    end
  end
end
