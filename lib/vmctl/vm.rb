# frozen_string_literal: true
# lib/vmctl/vm.rb
module VMCtl
  # One VM: turns an inventory entry + defaults into the exact bhyve invocation
  # and the on-disk paths vmctl manages.
  class VM
    attr_reader :entry, :defaults

    def initialize(entry, defaults)
      @entry = entry
      @defaults = defaults
    end

    def name
      @entry.name
    end

    def bhyve_argv
      argv = ['bhyve', '-k', template_path,
              '-o', "network=#{@entry.network}",
              '-o', "link=#{@entry.link}"]
      argv += ['-o', "mac=#{@entry.mac}"] if @entry.mac
      argv << name
      argv
    end

    def bhyve_command
      bhyve_argv.join(' ')
    end

    # Like bhyve_command, but appends `-o config.dump=1` so bhyve prints the
    # fully-resolved config and exits without booting.
    def dump_command
      argv = bhyve_argv
      argv.insert(-2, '-o', 'config.dump=1')
      argv.join(' ')
    end

    def template_path
      File.join(@defaults.config_dir, @entry.config)
    end

    def dir
      File.join(@defaults.vm_root, name)
    end

    def pidfile
      File.join(@defaults.run_dir, "#{name}.pid")
    end

    def logfile
      File.join(@defaults.log_dir, "#{name}.log")
    end

    def vmm_device
      "/dev/vmm/#{name}"
    end

    def console_device
      "/dev/nmdm#{@entry.link}B"
    end

    def disk_paths
      @entry.disks.map { |d| File.join(dir, d.file) }
    end

    def running?(executor)
      executor.success?("test -e #{vmm_device}")
    end

    def read_pid
      return nil unless File.exist?(pidfile)
      Integer(File.read(pidfile).strip)
    rescue StandardError
      nil
    end
  end
end
