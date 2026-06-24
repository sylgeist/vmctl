# frozen_string_literal: true
# lib/vmctl/commands/base.rb
require_relative '../vm'

module VMCtl
  module Commands
    class CommandError < StandardError; end

    class Base
      def initialize(config:, executor:)
        @config = config
        @executor = executor
      end

      protected

      attr_reader :config, :executor

      def vm_for(name)
        entry = config.vms[name]
        raise CommandError, "unknown VM '#{name}'" unless entry
        VM.new(entry, config.defaults)
      end

      # Resolve a target list from args: explicit names, or all VMs (--all),
      # optionally restricted to autostart VMs.
      def targets(names, all:, autostart_only: false)
        if all
          entries = config.vms.values
          entries = entries.select(&:autostart) if autostart_only
          entries.map { |e| VM.new(e, config.defaults) }
        else
          names.map { |n| vm_for(n) }
        end
      end

      # Print a "takes effect on next start" notice when the VM is running.
      # All modify commands edit the inventory, which is re-rendered at start.
      def note_next_boot(vm, what)
        return unless vm.running?(executor)
        puts "note: #{vm.name} is running; #{what} takes effect on next start"
      end

      # Resolve a disk on a VM by its suffix (file is "<name>-<suffix>.raw").
      def disk_for(vm, suffix)
        file = "#{vm.name}-#{suffix}.raw"
        disk = vm.entry.disks.find { |d| d.file == file }
        raise CommandError, "#{vm.name} has no disk '#{suffix}'" unless disk
        disk
      end

      # A VM with iso: needs a template that consumes %(iso), and vice versa —
      # otherwise bhyve sees an undefined config variable or an empty CD path.
      def validate_iso_pairing!(vm)
        if vm.entry.iso && !vm.template_wants_iso?
          raise CommandError,
                "template #{vm.entry.config} does not reference %(iso) (use an installer template)"
        end
        if !vm.entry.iso && vm.template_wants_iso?
          raise CommandError,
                "template #{vm.entry.config} references %(iso) but VM #{vm.name} has no iso"
        end
      end
    end
  end
end
