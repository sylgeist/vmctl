# frozen_string_literal: true
# lib/vmctl/commands/add_nic.rb
require 'optparse'
require_relative 'base'
require_relative '../netgraph'
require_relative '../allocator'

module VMCtl
  module Commands
    # add-nic <vm> <bridge> [--mtu N] [--mac generate|<addr>]
    class AddNic < Base
      MAC_RE = /\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/i.freeze

      def call(args)
        opts = {}
        parser = OptionParser.new do |p|
          p.on('--mtu N')  { |v| opts[:mtu] = v }
          p.on('--mac MAC') { |v| opts[:mac] = v }
        end
        rest = parser.parse(args)
        name, bridge = rest.shift(2)
        raise CommandError, 'add-nic requires <vm> <bridge>' unless name && bridge
        vm = vm_for(name)
        if vm.nic_count >= 8
          raise CommandError, "#{name} already has 8 NICs (max 8: pci.0.4.0-7)"
        end
        Netgraph.new(executor).ensure_bridge!(bridge)
        nic = Nic.new(bridge: bridge, mtu: parse_mtu(opts[:mtu]), mac: resolve_mac(vm, opts[:mac]))
        (vm.entry.networks ||= []) << nic
        config.save(config.path) unless executor.dry_run?
        puts "added nic on #{bridge} (pci.0.4.#{vm.nic_count - 1}) to #{name}"
        note_next_boot(vm, 'the new nic')
      end

      private

      def parse_mtu(v)
        return nil if v.nil?
        n = Integer(v, exception: false)
        raise CommandError, "invalid --mtu #{v.inspect}" if n.nil? || n <= 0
        n
      end

      def resolve_mac(vm, mac)
        return nil if mac.nil?
        return Allocator.new(config).generate_mac(vm.name, (vm.entry.networks || []).length + 1) if mac == 'generate'
        raise CommandError, "invalid --mac #{mac.inspect}" unless mac =~ MAC_RE
        mac
      end
    end
  end
end
