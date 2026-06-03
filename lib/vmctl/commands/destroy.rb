# frozen_string_literal: true
# lib/vmctl/commands/destroy.rb
require 'optparse'
require_relative 'base'

module VMCtl
  module Commands
    class Destroy < Base
      def call(args)
        opts = parse(args)
        name = opts[:name]
        raise CommandError, 'destroy requires a VM name' unless name
        vm = vm_for(name) # raises CommandError for unknown VM
        raise CommandError, "#{name} is running — stop it first" if vm.running?(executor)

        confirm!(name) unless opts[:yes]

        executor.run("zfs destroy #{config.defaults.zpool}/#{name}") if opts[:purge]
        config.remove_vm(name)
        config.save(config.path) unless executor.dry_run?
        puts "destroyed #{name}#{opts[:purge] ? ' (dataset purged)' : ''}"
      end

      private

      def parse(args)
        o = {}
        parser = OptionParser.new do |p|
          p.on('--purge') { o[:purge] = true }
          p.on('--yes')   { o[:yes] = true }
        end
        rest = parser.parse(args)
        o[:name] = rest.shift
        o
      end

      def confirm!(name)
        $stdout.print "Destroy #{name}? type 'yes' to confirm: "
        $stdout.flush
        answer = $stdin.gets&.strip
        raise CommandError, 'aborted' unless answer == 'yes'
      end
    end
  end
end
