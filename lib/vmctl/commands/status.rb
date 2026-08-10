# frozen_string_literal: true
# lib/vmctl/commands/status.rb
require_relative 'base'

module VMCtl
  module Commands
    class Status < Base
      STATE_COLORS = { running: :green, stopped: :gray, stale: :yellow }.freeze

      def call(args)
        all = args.delete('--all')
        vms = targets(args, all: all || args.empty?)
        rows = vms.map { |vm| row_for(vm) }
        return if rows.empty?

        Output.table(%w[NAME STATE NETWORK], rows.map { |r| table_row(r) })
        print_stale_hints(rows)
      end

      private

      def row_for(vm)
        net = "#{vm.entry.network} link #{vm.entry.link}"
        net = "#{net}  vnc #{vm.vnc_endpoint}" if vm.entry.graphics

        if !vm.running?(executor)
          { name: vm.name, state: :stopped, state_text: 'stopped', network: net }
        elsif vm.supervisor_alive?(executor)
          { name: vm.name, state: :running, state_text: "running (pid #{vm.read_pid})", network: net }
        else
          { name: vm.name, state: :stale, state_text: 'stale', network: net }
        end
      end

      def table_row(r)
        [r[:name], Output.colorize(r[:state_text], STATE_COLORS.fetch(r[:state])), r[:network]]
      end

      def print_stale_hints(rows)
        rows.select { |r| r[:state] == :stale }.each do |r|
          hint = "  ! #{r[:name]}: no live supervisor; run 'vmctl stop --force #{r[:name]}'"
          puts Output.colorize(hint, :yellow)
        end
      end
    end
  end
end
