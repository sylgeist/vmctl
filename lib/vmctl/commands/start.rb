# frozen_string_literal: true
# lib/vmctl/commands/start.rb
require_relative 'base'
require_relative '../netgraph'
require_relative '../supervisor'

module VMCtl
  module Commands
    class Start < Base
      def initialize(config:, executor:, supervisor_factory: nil)
        super(config: config, executor: executor)
        @factory = supervisor_factory ||
                   ->(vm, **kw) { Supervisor.new(vm, executor: executor, **kw) }
        @netgraph = Netgraph.new(executor)
      end

      def call(args)
        all = !!args.delete('--all')
        vms = targets(args, all: all, autostart_only: all)
        vms.each { |vm| start_one(vm) }
      end

      private

      def start_one(vm)
        raise CommandError, "#{vm.name} already running" if vm.running?(executor)
        @netgraph.ensure_bridge!(vm.entry.network)
        sup = @factory.call(vm)
        pid = sup.start
        puts "started #{vm.name} (supervisor pid #{pid})"
      end
    end
  end
end
