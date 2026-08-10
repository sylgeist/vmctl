# frozen_string_literal: true
# lib/vmctl/commands/list.rb
require_relative 'base'

module VMCtl
  module Commands
    class List < Base
      def call(_args)
        entries = config.vms.values
        return if entries.empty?

        rows = entries.map do |e|
          [e.name, "#{e.network} link #{e.link}", e.mac || '', e.autostart ? 'yes' : '']
        end
        Output.table(%w[NAME NETWORK MAC AUTOSTART], rows)
      end
    end
  end
end
