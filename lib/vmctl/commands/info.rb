# frozen_string_literal: true
# lib/vmctl/commands/info.rb
require_relative 'base'

module VMCtl
  module Commands
    # Read-only per-VM resource summary: run state plus the resolved allocation
    # (cpus/memory/disks/networks). Complements `status` (liveness only) and
    # `dump` (the full rendered bhyve config).
    class Info < Base
      def call(args)
        all = args.delete('--all')
        vms = targets(args, all: all || args.empty?)
        puts vms.map { |vm| block_for(vm) }.join("\n\n")
      end

      private

      def block_for(vm)
        lines = ["#{vm.name}: #{state(vm)}"]
        lines << row('cpus', cpus(vm))
        lines << row('memory', memory(vm))
        labeled('disks', disk_rows(vm), lines)
        labeled('network', net_rows(vm), lines)
        lines.join("\n")
      end

      # A label + value line; the label column is padded so values align.
      def row(label, value)
        format('  %-8s %s', label, value)
      end

      # Emit rows for a repeatable section: the label appears only on the first
      # row, continuation rows keep the alignment with a blank label.
      def labeled(label, rows, lines)
        rows.each_with_index do |value, i|
          lines << row(i.zero? ? label : '', value)
        end
      end

      def state(vm)
        return 'stopped' unless vm.running?(executor)
        return "running (pid #{vm.read_pid})" if vm.supervisor_alive?(executor)
        'stale'
      end

      def cpus(vm)
        vm.resolved_config['cpus']
      end

      def memory(vm)
        mem = vm.resolved_config['memory.size']
        vm.resolved_config['memory.wired'] == 'true' ? "#{mem}  (wired)" : mem
      end

      def disk_rows(vm)
        vm.entry.disks.zip(vm.disk_paths).map do |disk, path|
          suffix = disk.file.sub(/\A#{Regexp.escape(vm.name)}-/, '').sub(/\.raw\z/, '')
          format('%-6s %-6s %s', suffix, disk.size, path)
        end
      end

      def net_rows(vm)
        e = vm.entry
        rows = []
        rows << "#{e.network}  link #{e.link}" unless e.network.nil? || e.network == 'none'
        (e.networks || []).each { |n| rows << n.bridge }
        rows
      end
    end
  end
end
