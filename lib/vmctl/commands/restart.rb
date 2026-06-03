# frozen_string_literal: true
# lib/vmctl/commands/restart.rb
require_relative 'base'
require_relative 'stop'
require_relative 'start'

module VMCtl
  module Commands
    class Restart < Base
      def call(args)
        name = args.first
        raise CommandError, 'restart requires a VM name' unless name
        Stop.new(config: config, executor: executor).call([name])
        Start.new(config: config, executor: executor).call([name])
      end
    end
  end
end
