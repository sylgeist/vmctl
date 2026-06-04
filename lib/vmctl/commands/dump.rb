# frozen_string_literal: true
# lib/vmctl/commands/dump.rb
require_relative 'base'

module VMCtl
  module Commands
    # Prints a VM's fully-resolved bhyve config (bhyve -o config.dump=1), which
    # dumps the merged configuration and exits without booting. Read-only.
    class Dump < Base
      def call(args)
        name = args.first
        raise CommandError, 'dump requires a VM name' unless name
        vm = vm_for(name)
        puts executor.capture(vm.dump_command)
      end
    end
  end
end
