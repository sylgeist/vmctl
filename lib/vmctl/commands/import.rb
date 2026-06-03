# frozen_string_literal: true
# lib/vmctl/commands/import.rb
require 'optparse'
require_relative 'base'
require_relative '../allocator'
require_relative '../sizes'

module VMCtl
  module Commands
    class Import < Base
      def call(args)
        opts = parse(args)
        name = opts[:name]
        raise CommandError, 'import requires a VM name' unless name
        raise CommandError, "VM '#{name}' already exists" if config.vms.key?(name)
        raise CommandError, '--network is required' unless opts[:network]

        dir = File.join(config.defaults.vm_root, name)
        raise CommandError, "dataset dir not found: #{dir}" unless File.directory?(dir)
        raws = Dir.glob(File.join(dir, '*.raw')).sort
        raise CommandError, "no .raw images found in #{dir}" if raws.empty?

        entry = VMEntry.new(
          name: name,
          config: opts[:config] || config.defaults.template,
          network: opts[:network],
          link: Allocator.new(config).next_link,
          mac: opts[:mac],
          autostart: false,
          disks: raws.map { |p| Disk.new(file: File.basename(p), size: Sizes.human(File.size(p)), from: nil) },
          cloud_init: nil
        )
        config.add_vm(entry)
        config.save(config.path) unless executor.dry_run?
        puts "imported #{name} (link #{entry.link}, #{entry.disks.length} disk(s))"
      end

      private

      def parse(args)
        o = {}
        parser = OptionParser.new do |p|
          p.on('--network NET') { |v| o[:network] = v }
          p.on('--config TMPL') { |v| o[:config] = v }
          p.on('--mac MAC')     { |v| o[:mac] = v }
        end
        rest = parser.parse(args)
        o[:name] = rest.shift
        o
      end
    end
  end
end
