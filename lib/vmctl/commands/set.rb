# frozen_string_literal: true
# lib/vmctl/commands/set.rb
require 'optparse'
require_relative 'base'
require_relative '../netgraph'
require_relative '../allocator'

module VMCtl
  module Commands
    # set <vm> [field flags]  -- edit scalar inventory fields.
    class Set < Base
      def call(args)
        opts = {}
        parser = OptionParser.new do |p|
          p.on('--autostart')    { opts[:autostart] = true }
          p.on('--no-autostart') { opts[:autostart] = false }
          p.on('--network NET')  { |v| opts[:network] = v }
          p.on('--mac MAC')      { |v| opts[:mac] = v }
          p.on('--config TMPL')  { |v| opts[:config] = v }
          p.on('--iso FILE')     { |v| opts[:iso] = v }
          p.on('--no-iso')       { opts[:iso] = false }
        end
        rest = parser.parse(args)
        name = rest.shift
        raise CommandError, 'set requires a VM name' unless name
        raise CommandError, 'set requires at least one field to change' if opts.empty?
        vm = vm_for(name)
        changed = apply!(vm, opts)
        config.save(config.path) unless executor.dry_run?
        puts "updated #{name}: #{changed.join(', ')}"
        note_next_boot(vm, 'these changes')
      end

      private

      def apply!(vm, opts)
        e = vm.entry
        changed = []
        if opts.key?(:autostart)
          e.autostart = opts[:autostart]
          changed << "autostart=#{e.autostart}"
        end
        if opts.key?(:network)
          Netgraph.new(executor).ensure_bridge!(opts[:network])
          e.network = opts[:network]
          changed << "network=#{e.network}"
        end
        if opts.key?(:mac)
          e.mac = resolve_mac(opts[:mac], vm.name)
          changed << "mac=#{e.mac}"
        end
        if opts.key?(:config)
          validate_template!(opts[:config])
          e.config = opts[:config]
          changed << "config=#{e.config}"
        end
        apply_iso!(vm, opts[:iso], changed) if opts.key?(:iso)
        changed
      end

      def resolve_mac(mac, name)
        return Allocator.new(config).generate_mac(name) if mac == 'generate'
        mac
      end

      def validate_template!(tmpl)
        path = File.join(config.defaults.config_dir, tmpl)
        raise CommandError, "template not found: #{path}" unless File.exist?(path)
      end

      def apply_iso!(vm, iso, changed)
        e = vm.entry
        if iso == false
          e.iso = nil
          changed << 'iso=(none)'
        else
          path = File.expand_path(iso)
          raise CommandError, "iso not found: #{path}" unless File.exist?(path)
          e.iso = path
          changed << "iso=#{path}"
          validate_iso_pairing!(vm)
        end
      end
    end
  end
end
