# frozen_string_literal: true
# lib/vmctl/cli.rb
require 'optparse'
require_relative 'version'
require_relative 'log'
require_relative 'config'
require_relative 'executor'
require_relative 'netgraph'
require_relative 'commands/base'
require_relative 'commands/list'
require_relative 'commands/status'
require_relative 'commands/start'
require_relative 'commands/stop'
require_relative 'commands/restart'
require_relative 'commands/console'
require_relative 'commands/dump'
require_relative 'commands/create'
require_relative 'commands/import'
require_relative 'commands/destroy'
require_relative 'commands/add_disk'

module VMCtl
  module CLI
    DEFAULT_CONFIG = '/usr/local/etc/vmctl/inventory.yml'

    USAGE = <<~USAGE
      Usage: vmctl [options] <command> [args]

      Commands:
        start [name|--all]    Start VM(s) under a supervisor.
        stop  [name|--all]    Graceful ACPI poweroff, then destroy on timeout.
        restart <name>        Graceful stop then start.
        status [name]         Running/stopped, pid, link, network.
        console <name>        Attach to the VM's nmdm console.
        dump <name>           Print the VM's fully-resolved bhyve config (config.dump).
        create <name>         Allocate + provision a new VM (--network NET).
        import <name>         Adopt an existing (zfs-recv'd) VM's disks.
        destroy <name>        Remove a VM (--purge also destroys its dataset).
        add-disk <name> <spec>  Add a disk (suffix:size[:from img]) to an existing VM.
        list                  List configured VMs.
        help                  Show this message.

      Options:
        -c, --config FILE     Inventory file (default: #{DEFAULT_CONFIG})
        -v, --verbose         Verbose output
        -n, --dry-run         Print actions without executing
        -V, --version         Print version and exit
    USAGE

    COMMANDS = {
      'list'    => Commands::List,
      'status'  => Commands::Status,
      'start'   => Commands::Start,
      'stop'    => Commands::Stop,
      'restart' => Commands::Restart,
      'console' => Commands::Console,
      'dump'    => Commands::Dump,
      'create'  => Commands::Create,
      'import'  => Commands::Import,
      'destroy'  => Commands::Destroy,
      'add-disk' => Commands::AddDisk
    }.freeze

    def self.run(argv)
      options = { config: DEFAULT_CONFIG, verbose: false, dry_run: false }
      parser = OptionParser.new do |o|
        o.on('-c', '--config FILE') { |f| options[:config] = f }
        o.on('-v', '--verbose')     { options[:verbose] = true }
        o.on('-n', '--dry-run')     { options[:dry_run] = true }
        o.on('-V', '--version')     { puts "vmctl #{VERSION}"; exit 0 }
        o.on('-h', '--help')        { puts USAGE; exit 0 }
      end

      begin
        parser.order!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        exit 2
      end

      VMCtl.log_level = options[:verbose] ? Logger::DEBUG : Logger::INFO

      cmd = argv.shift
      if cmd.nil?
        warn USAGE
        exit 2
      end
      if cmd == 'help'
        puts USAGE
        exit 0
      end

      klass = COMMANDS[cmd]
      unless klass
        warn "unknown command: #{cmd}"
        warn USAGE
        exit 2
      end

      begin
        config = Config.load(options[:config])
        executor = Executor.new(dry_run: options[:dry_run])
        klass.new(config: config, executor: executor).call(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        exit 2
      rescue ConfigError, Commands::CommandError,
             NetgraphError, ExecutorError => e
        warn "error: #{e.message}"
        exit 1
      end
    end
  end
end
