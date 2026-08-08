# frozen_string_literal: true
# lib/vmctl/commands/status.rb
require_relative 'base'

module VMCtl
  module Commands
    class Status < Base
      STATE_COLORS = { running: 32, stopped: 90, stale: 33 }.freeze

      def call(args)
        all = args.delete('--all')
        vms = targets(args, all: all || args.empty?)
        rows = vms.map { |vm| row_for(vm) }
        return if rows.empty?

        print_table(rows)
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

      # Columns are sized to the actual data so names/states of any length
      # (single VM or the whole fleet) line up without wasted padding.
      def print_table(rows)
        name_w = ([4] + rows.map { |r| r[:name].length }).max
        state_w = ([5] + rows.map { |r| r[:state_text].length }).max

        puts format('%-*s  %-*s  %s', name_w, 'NAME', state_w, 'STATE', 'NETWORK')
        rows.each do |r|
          state = colorize(r[:state_text].ljust(state_w), STATE_COLORS.fetch(r[:state]))
          puts "#{r[:name].ljust(name_w)}  #{state}  #{r[:network]}"
        end
      end

      def print_stale_hints(rows)
        rows.select { |r| r[:state] == :stale }.each do |r|
          hint = "  ! #{r[:name]}: no live supervisor; run 'vmctl stop --force #{r[:name]}'"
          puts colorize(hint, STATE_COLORS.fetch(:stale))
        end
      end

      def colorize(text, code)
        return text unless $stdout.tty?
        "\e[#{code}m#{text}\e[0m"
      end
    end
  end
end
