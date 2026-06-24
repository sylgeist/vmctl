# frozen_string_literal: true
# lib/vmctl/commands/grow_disk.rb
require_relative 'base'
require_relative '../provisioner'
require_relative '../sizes'

module VMCtl
  module Commands
    # grow-disk <vm> <suffix> <new-size>  (grow-only; never shrinks)
    class GrowDisk < Base
      def call(args)
        name, suffix, new_size = args.shift(3)
        unless name && suffix && new_size
          raise CommandError, 'grow-disk requires <vm> <suffix> <new-size>'
        end
        vm = vm_for(name)
        disk = disk_for(vm, suffix)
        validate_grow!(disk, new_size)
        Provisioner.new(executor, config.defaults)
                   .grow_disk(File.join(vm.dir, disk.file), new_size)
        disk.size = new_size
        config.save(config.path) unless executor.dry_run?
        puts "grew #{disk.file} to #{new_size} (grow the guest filesystem after reboot)"
        note_next_boot(vm, 'the larger disk')
      end

      private

      def validate_grow!(disk, new_size)
        begin
          requested = Sizes.parse(new_size)
        rescue ArgumentError
          raise CommandError, "invalid size #{new_size.inspect}"
        end
        return if requested > Sizes.parse(disk.size)
        raise CommandError,
              "new size #{new_size} is not larger than current #{disk.size}"
      end
    end
  end
end
