# frozen_string_literal: true
# lib/vmctl/commands/add_disk.rb
require_relative 'base'
require_relative '../provisioner'
require_relative '../sizes'

module VMCtl
  module Commands
    # add-disk <vm> <suffix>:<size>[:from <image>]
    # Provisions a new raw disk and appends it to the VM's inventory.
    class AddDisk < Base
      def call(args)
        name = args.shift
        spec = args.shift
        unless name && spec
          raise CommandError, 'add-disk requires <vm> <suffix>:<size>[:from image]'
        end
        vm = vm_for(name)
        disk = parse_spec(name, spec)
        validate!(vm, disk)
        provisioner.create_disk(File.join(vm.dir, disk.file), disk.size, from: disk.from)
        vm.entry.disks << disk
        config.save(config.path) unless executor.dry_run?
        puts "added disk #{disk.file} (#{disk.size}) to #{name}"
        note_next_boot(vm, 'the new disk')
      end

      private

      def provisioner
        @provisioner ||= Provisioner.new(executor, config.defaults)
      end

      def parse_spec(name, spec)
        Disk.parse(name, spec)
      rescue ArgumentError => e
        raise CommandError, e.message
      end

      def validate!(vm, disk)
        if vm.entry.disks.any? { |d| d.file == disk.file }
          raise CommandError, "#{vm.name} already has disk #{disk.file}"
        end
        if vm.entry.disks.length >= 8
          raise CommandError, "#{vm.name} already has 8 disks (pci.0.3 slot full)"
        end
        begin
          requested = Sizes.parse(disk.size)
        rescue ArgumentError
          raise CommandError, "invalid size #{disk.size.inspect}"
        end
        return unless disk.from
        image = provisioner.image_path(disk.from)
        raise CommandError, "image not found: #{image}" unless File.exist?(image)
        if requested < File.size(image)
          raise CommandError, "disk size #{disk.size} is smaller than image #{disk.from}"
        end
      end
    end
  end
end
