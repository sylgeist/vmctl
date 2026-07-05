# frozen_string_literal: true
# lib/vmctl/commands/remove_nic.rb
require_relative 'base'

module VMCtl
  module Commands
    # remove-nic <vm> <index>  -- index is the 1-based position in `networks:`
    # (additional NICs only; the primary is changed via `set --network none`).
    class RemoveNic < Base
      def call(args)
        name, index = args.shift(2)
        raise CommandError, 'remove-nic requires <vm> <index>' unless name && index
        vm = vm_for(name)
        nets = vm.entry.networks || []
        i = Integer(index, exception: false)
        unless i && i >= 1 && i <= nets.length
          raise CommandError, "#{name} has no additional nic ##{index} (has #{nets.length})"
        end
        removed = nets.delete_at(i - 1)
        config.save(config.path) unless executor.dry_run?
        puts "removed nic ##{i} on #{removed.bridge} from #{name}"
        note_next_boot(vm, 'the nic removal')
      end
    end
  end
end
