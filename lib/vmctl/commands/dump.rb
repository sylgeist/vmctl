# frozen_string_literal: true
# lib/vmctl/commands/dump.rb
require_relative 'base'

module VMCtl
  module Commands
    # Print a VM's fully-resolved bhyve config (base flavor + inventory, with
    # disks generated). Read-only; renders the same text `start` writes.
    class Dump < Base
      def call(args)
        name = args.first
        raise CommandError, 'dump requires a VM name' unless name
        vm = vm_for(name)
        begin
          print vm.render_config
        rescue Errno::ENOENT => e
          raise CommandError, "could not render config for #{vm.name}: #{e.message}"
        end
      end
    end
  end
end
