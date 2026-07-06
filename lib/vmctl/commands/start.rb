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
        if executor.dry_run?
          puts "[dry-run] #{vm.bhyve_command}"
          return
        end
        if vm.running?(executor)
          if vm.stale?(executor)
            raise CommandError,
                  "#{vm.name} has a stale vmm device — run 'vmctl stop --force #{vm.name}' first"
          end
          raise CommandError, "#{vm.name} already running"
        end
        if vm.nic_count > 8
          raise CommandError, "#{vm.name} has #{vm.nic_count} NICs (max 8: pci.0.4.0-7)"
        end
        vm.nic_bridges.each { |b| @netgraph.ensure_bridge!(b) }
        ensure_bootrom!(vm)
        vm.write_config
        sup = @factory.call(vm)
        pid = sup.start
        puts "started #{vm.name} (supervisor pid #{pid})"
      end

      def ensure_bootrom!(vm)
        rom = vm.resolved_config['bootrom']
        return if rom.nil?
        return if executor.success?('test', '-e', rom)
        raise CommandError,
              "bootrom not found: #{rom} (install the uefi-edk2-bhyve package?)"
      end
    end
  end
end
