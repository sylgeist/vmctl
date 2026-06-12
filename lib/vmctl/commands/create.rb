# frozen_string_literal: true
# lib/vmctl/commands/create.rb
require 'optparse'
require_relative 'base'
require_relative '../allocator'
require_relative '../netgraph'
require_relative '../provisioner'
require_relative '../cloudinit'
require_relative '../sizes'
require_relative 'start'

module VMCtl
  module Commands
    class Create < Base
      def call(args)
        opts = parse(args)
        name = opts[:name]
        raise CommandError, 'create requires a VM name' unless name
        raise CommandError, "VM '#{name}' already exists" if config.vms.key?(name)
        raise CommandError, '--network is required' unless opts[:network]

        entry = build_entry(name, opts)
        vm = VM.new(entry, config.defaults)
        provisioner = Provisioner.new(executor, config.defaults)
        validate!(vm, entry, opts, provisioner)

        provision(vm, entry, provisioner)
        cloud_init(vm, entry, opts[:cloud_init]) if opts[:cloud_init]

        config.add_vm(entry)
        config.save(config.path) unless executor.dry_run?
        puts "created #{name} (link #{entry.link})"

        Start.new(config: config, executor: executor).call([name]) if opts[:start]
      end

      private

      def parse(args)
        o = { disks: [] }
        parser = OptionParser.new do |p|
          p.on('--network NET') { |v| o[:network] = v }
          p.on('--config TMPL') { |v| o[:config] = v }
          p.on('--mac MAC')     { |v| o[:mac] = v }
          p.on('--root-size SIZE') { |v| o[:root_size] = v }
          p.on('--root-from IMG')  { |v| o[:root_from] = v }
          p.on('--disk SPEC')   { |v| o[:disks] << v }
          p.on('--cloud-init FILE') { |v| o[:cloud_init] = v }
          p.on('--iso FILE')    { |v| o[:iso] = v }
          p.on('--autostart')   { o[:autostart] = true }
          p.on('--start')       { o[:start] = true }
        end
        rest = parser.parse(args)
        o[:name] = rest.shift
        o
      end

      def build_entry(name, opts)
        d = config.defaults
        allocator = Allocator.new(config)
        disks = [Disk.new(
          file: "#{name}-root.raw",
          size: opts[:root_size] || d.root_size,
          from: opts.key?(:root_from) ? opts[:root_from] : d.root_from
        )]
        opts[:disks].each { |spec| disks << parse_disk(name, spec) }
        VMEntry.new(
          name: name,
          config: opts[:config] || d.template,
          network: opts[:network],
          link: allocator.next_link,
          mac: resolve_mac(allocator, name, opts[:mac]),
          autostart: !!opts[:autostart],
          disks: disks,
          cloud_init: nil,
          iso: opts[:iso] && File.expand_path(opts[:iso])
        )
      end

      # --disk grammar: "<suffix>:<size>[:from <image>]"
      #   e.g. "zfs:100G" or "data:50G:from gold.raw"
      def parse_disk(name, spec)
        body, from = spec.split(':from ', 2)
        suffix, size = body.split(':', 2)
        if suffix.to_s.empty? || size.to_s.empty?
          raise CommandError, "invalid --disk #{spec.inspect} (expected suffix:size)"
        end
        Disk.new(file: "#{name}-#{suffix}.raw", size: size, from: from)
      end

      def resolve_mac(allocator, name, mac)
        return nil if mac.nil?
        return allocator.generate_mac(name) if mac == 'generate'
        mac
      end

      def validate!(vm, entry, opts, provisioner)
        Netgraph.new(executor).ensure_bridge!(entry.network)
        raise CommandError, "template not found: #{vm.template_path}" unless File.exist?(vm.template_path)
        if entry.iso && !File.exist?(entry.iso)
          raise CommandError, "iso not found: #{entry.iso}"
        end
        validate_iso_pairing!(vm)
        raise CommandError, "dataset dir already exists: #{vm.dir}" if File.exist?(vm.dir)
        entry.disks.each do |disk|
          begin
            requested = Sizes.parse(disk.size)
          rescue ArgumentError
            raise CommandError, "disk #{disk.file} has invalid size #{disk.size.inspect}"
          end
          next unless disk.from
          image = provisioner.image_path(disk.from)
          raise CommandError, "image not found: #{image}" unless File.exist?(image)
          if requested < File.size(image)
            raise CommandError, "disk #{disk.file} size #{disk.size} is smaller than image #{disk.from}"
          end
        end
        if opts[:cloud_init] && !File.exist?(opts[:cloud_init])
          raise CommandError, "cloud-init file not found: #{opts[:cloud_init]}"
        end
      end

      def provision(vm, entry, provisioner)
        provisioner.create_dataset(vm)
        entry.disks.each do |disk|
          provisioner.create_disk(File.join(vm.dir, disk.file), disk.size, from: disk.from)
        end
      end

      def cloud_init(vm, entry, user_data)
        CloudInit.new(executor).build_seed(vm, user_data)
        dest = File.join(vm.dir, "#{vm.name}-user-data.yml")
        executor.run("cp #{user_data} #{dest}")
        entry.cloud_init = { 'user_data' => "#{vm.name}-user-data.yml" }
      end
    end
  end
end
