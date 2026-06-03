# frozen_string_literal: true
# lib/vmctl/commands/list.rb
require_relative 'base'

module VMCtl
  module Commands
    class List < Base
      def call(_args)
        config.vms.each_value do |e|
          mac = e.mac ? " mac #{e.mac}" : ''
          auto = e.autostart ? ' [autostart]' : ''
          puts "#{e.name}: #{e.network} link #{e.link}#{mac}#{auto}"
        end
      end
    end
  end
end
