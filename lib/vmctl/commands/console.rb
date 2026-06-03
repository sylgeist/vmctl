# frozen_string_literal: true
# lib/vmctl/commands/console.rb
require_relative 'base'

module VMCtl
  module Commands
    class Console < Base
      def call(args)
        name = args.first
        raise CommandError, 'console requires a VM name' unless name
        vm = vm_for(name)
        puts "attaching to #{vm.name} console (#{vm.console_device}); ~. to detach"
        # Intentionally bypasses Executor: cu replaces this process for an
        # interactive session, which the Open3-based Executor cannot model.
        exec('cu', '-l', vm.console_device) unless ENV['VMCTL_NO_EXEC'] == '1'
      end
    end
  end
end
