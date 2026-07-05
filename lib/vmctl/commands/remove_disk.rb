# frozen_string_literal: true
# lib/vmctl/commands/remove_disk.rb
require 'optparse'
require_relative 'base'

module VMCtl
  module Commands
    # remove-disk <vm> <suffix> [--purge]
    # Drops a disk from the inventory; --purge also deletes the backing file.
    class RemoveDisk < Base
      def call(args)
        purge = false
        parser = OptionParser.new { |p| p.on('--purge') { purge = true } }
        rest = parser.parse(args)
        name, suffix = rest.shift(2)
        raise CommandError, 'remove-disk requires <vm> <suffix>' unless name && suffix
        raise CommandError, "refusing to remove the root disk of #{name}" if suffix == 'root'
        vm = vm_for(name)
        disk = disk_for(vm, suffix)
        if purge && vm.running?(executor)
          raise CommandError,
                "#{name} is running; stop it before --purge (cannot delete an in-use disk)"
        end
        vm.entry.disks.delete(disk)
        detail = purge ? purge_file(vm, disk) : "(file #{disk.file} left in place)"
        config.save(config.path) unless executor.dry_run?
        puts "removed disk #{disk.file} from #{name} #{detail}"
        note_next_boot(vm, 'the disk removal')
      end

      private

      def purge_file(vm, disk)
        executor.run('rm', '-f', File.join(vm.dir, disk.file))
        'and purged its file'
      end
    end
  end
end
