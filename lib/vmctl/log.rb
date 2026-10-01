# frozen_string_literal: true
# lib/vmctl/log.rb
#
# A minimal logger, stdlib-only: Ruby 4 moved `logger` out of the default gems,
# and vmctl must run on a bare ruby (FreeBSD quarterly has no ruby40 gems).
# Output: "[SEV] vmctl: msg", or "[SEV] vmctl[<vm>]: msg" inside a VM thread.

module VMCtl
  class Log
    DEBUG = 0
    INFO = 1
    WARN = 2
    ERROR = 3
    FATAL = 4
    NAMES = %w[DEBUG INFO WARN ERROR FATAL].freeze

    attr_accessor :level

    def initialize(io, progname:, level: INFO)
      @io = io
      @progname = progname
      @level = level
      @mutex = Mutex.new
    end

    NAMES.each_with_index do |name, sev|
      define_method(name.downcase) { |msg| add(sev, msg) }
    end

    private

    def add(sev, msg)
      return if sev < @level

      tag = Thread.current[:vmctl_vm]
      prefix = tag ? "#{@progname}[#{tag}]" : @progname
      @mutex.synchronize { @io.write("[#{NAMES[sev]}] #{prefix}: #{msg}\n") }
    end
  end

  def self.logger
    @logger ||= Log.new($stderr, progname: 'vmctl')
  end

  def self.log_level=(level)
    logger.level = level
  end
end
