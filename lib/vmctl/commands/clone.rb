# frozen_string_literal: true
# lib/vmctl/commands/clone.rb
require 'optparse'
require_relative 'base'
require_relative '../allocator'
require_relative '../netgraph'
require_relative '../provisioner'
require_relative 'start'

module VMCtl
  module Commands
    class Clone < Base
      def call(args)
        opts = parse(args)
        source_name = opts[:source]
        new_name = opts[:name]
        raise CommandError, 'clone requires a source VM and a new name' unless source_name && new_name

        source_vm = vm_for(source_name) # raises CommandError for unknown VM
        raise CommandError, "VM '#{new_name}' already exists" if config.vms.key?(new_name)

        entry = build_entry(source_vm.entry, new_name, opts)
        dest_vm = VM.new(entry, config.defaults)
        provisioner = Provisioner.new(executor, config.defaults)
        validate!(source_vm, dest_vm, opts)

        provisioner.clone_dataset(source_vm, dest_vm)
        config.add_vm(entry)
        config.save(config.path) unless executor.dry_run?
        puts "cloned #{source_name} -> #{new_name} (link #{entry.link})"

        Start.new(config: config, executor: executor).call([new_name]) if opts[:start]
      end

      private

      def parse(args)
        o = {}
        parser = OptionParser.new do |p|
          p.on('--network NET') { |v| o[:network] = v }
          p.on('--mac MAC')     { |v| o[:mac] = v }
          p.on('--cpus N')      { |v| o[:cpus] = v }
          p.on('--memory SIZE') { |v| o[:memory] = v }
          p.on('--autostart')   { o[:autostart] = true }
          p.on('--force')       { o[:force] = true }
          p.on('--start')       { o[:start] = true }
        end
        rest = parser.parse(args)
        o[:source] = rest.shift
        o[:name]   = rest.shift
        o
      end

      def build_entry(src, new_name, opts)
        allocator = Allocator.new(config)
        VMEntry.new(
          name: new_name,
          config: src.config,
          network: opts[:network] || src.network,
          link: allocator.next_link,
          mac: clone_mac(allocator, new_name, src.mac, opts),
          autostart: !!opts[:autostart],
          disks: rename_disks(src.name, new_name, src.disks),
          cloud_init: src.cloud_init,
          iso: nil,
          options: src.options,
          mtu: src.mtu,
          networks: clone_networks(allocator, new_name, src.networks),
          cpus: opts[:cpus] ? positive_int!(opts[:cpus], '--cpus') : src.cpus,
          memory: opts[:memory] ? valid_size!(opts[:memory], '--memory') : src.memory,
          graphics: src.graphics,
          efi_vars: src.efi_vars,
          rtc_localtime: src.rtc_localtime,
          memory_wired: src.memory_wired,
          smbios: src.smbios
        )
      end

      # nil source MAC -> nil (bhyve auto); otherwise a fresh deterministic MAC.
      # --mac overrides the primary.
      def clone_mac(allocator, new_name, source_mac, opts)
        return opts[:mac] if opts[:mac]
        return nil if source_mac.nil?
        allocator.generate_mac(new_name)
      end

      # Additional NICs: keep bridge/mtu; regenerate a distinct MAC per index
      # (index 1+), leaving nil MACs as nil.
      def clone_networks(allocator, new_name, networks)
        return networks if networks.nil? || networks.empty?
        networks.each_with_index.map do |nic, i|
          mac = nic.mac.nil? ? nil : allocator.generate_mac(new_name, i + 1)
          Nic.new(bridge: nic.bridge, mtu: nic.mtu, mac: mac)
        end
      end

      # Swap the source name prefix on each disk file; leave non-prefixed as-is.
      def rename_disks(source_name, new_name, disks)
        disks.map do |d|
          new_file = d.file.sub(/\A#{Regexp.escape(source_name)}-/, "#{new_name}-")
          Disk.new(file: new_file, size: d.size, from: d.from)
        end
      end

      def validate!(source_vm, dest_vm, opts)
        raise CommandError, "dataset dir already exists: #{dest_vm.dir}" if File.exist?(dest_vm.dir)
        if source_vm.running?(executor) && !opts[:force]
          raise CommandError,
                "#{source_vm.name} is running — stop it first (or pass --force for a crash-consistent clone)"
        end
        warn "warning: #{source_vm.name} is running; clone is crash-consistent" if source_vm.running?(executor)
        ng = Netgraph.new(executor)
        dest_vm.nic_bridges.each { |b| ng.ensure_bridge!(b) }
      end
    end
  end
end
