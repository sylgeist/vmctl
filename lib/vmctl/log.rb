# frozen_string_literal: true
# lib/vmctl/log.rb
require 'logger'

module VMCtl
  def self.logger
    @logger ||= begin
      l = Logger.new($stderr)
      l.progname = 'vmctl'
      l.formatter = lambda do |sev, _t, prog, msg|
        tag = Thread.current[:vmctl_vm]
        prefix = tag ? "#{prog}[#{tag}]" : prog
        "[#{sev}] #{prefix}: #{msg}\n"
      end
      l
    end
  end

  def self.log_level=(level)
    logger.level = level
  end
end
