# frozen_string_literal: true
# lib/vmctl/commands/dump.rb
require_relative 'base'

module VMCtl
  module Commands
    # Prints a VM's fully-resolved bhyve config (bhyve -o config.dump=1), which
    # dumps the merged configuration to stdout and exits **non-zero by design**,
    # without booting. Read-only.
    class Dump < Base
      def call(args)
        name = args.first
        raise CommandError, 'dump requires a VM name' unless name
        vm = vm_for(name)
        # Don't treat config.dump's by-design non-zero exit as failure: the dump
        # is on stdout. A genuine failure (bad template) yields no stdout.
        out, err, = executor.capture_unchecked(vm.dump_command)
        if out.strip.empty?
          detail = err.strip.empty? ? '' : ": #{err.strip}"
          raise CommandError, "could not dump config for #{vm.name}#{detail}"
        end
        print out
      end
    end
  end
end
