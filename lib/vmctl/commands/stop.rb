# frozen_string_literal: true
# lib/vmctl/commands/stop.rb
require_relative 'base'
require 'optparse'

module VMCtl
  module Commands
    class Stop < Base
      def call(args)
        force = false
        all = false
        parser = OptionParser.new do |o|
          o.on('--force') { force = true }
          o.on('--all')   { all = true }
        end
        rest = parser.parse(args)
        vms = targets(rest, all: all)
        vms.each { |vm| stop_one(vm, force: force) }
      end

      private

      def stop_one(vm, force:)
        pid = vm.read_pid
        unless pid
          puts "#{vm.name} not running (no pidfile)"
          executor.run("bhyvectl --destroy --vm=#{vm.name}") if force
          return
        end

        if force
          safe_kill('KILL', pid)
          executor.run("bhyvectl --destroy --vm=#{vm.name}")
          puts "force-stopped #{vm.name}"
        else
          safe_kill('TERM', pid)
          puts "stopping #{vm.name} (graceful poweroff requested)"
        end
      end

      def safe_kill(sig, pid)
        Process.kill(sig, pid)
      rescue Errno::ESRCH
        # Process already gone; nothing to do.
      end
    end
  end
end
