# frozen_string_literal: true
# lib/vmctl/vm.rb
require 'fileutils'
require_relative 'config_renderer'
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

    def config_path
      File.join(@defaults.run_dir, "#{name}.conf")
    end

    def render_config
      ConfigRenderer.new(@defaults).render(self)
    end

    def write_config
      FileUtils.mkdir_p(@defaults.run_dir)
      File.binwrite(config_path, render_config)
      config_path
    end

    def bhyve_argv
      ['bhyve', '-k', config_path, name]
    end

    def bhyve_command
      bhyve_argv.join(' ')
    end

    def template_path
      File.join(@defaults.config_dir, @entry.config)
    end

    # True when the template consumes the %(iso) config variable on an active
    # (non-comment) line. False if the template file is missing — template
    # existence is validated elsewhere. Read as binary: templates are opaque
    # byte streams, and the host locale (e.g. LANG=C => US-ASCII) must not
    # make the scan raise on non-ASCII bytes in comments.
    def template_wants_iso?
      return false unless File.exist?(template_path)
      File.foreach(template_path, encoding: Encoding::BINARY).any? do |line|
        line.sub(/#.*/, '').include?('%(iso)')
      end
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

    # Bridges that must exist for this VM (primary unless `none`/nil, plus each
    # additional NIC). Used for start/create validation.
    def nic_bridges
      bridges = []
      bridges << @entry.network unless @entry.network.nil? || @entry.network == 'none'
      (@entry.networks || []).each { |n| bridges << n.bridge }
      bridges
    end

    def nic_count
      primary = (@entry.network.nil? || @entry.network == 'none') ? 0 : 1
      primary + (@entry.networks || []).length
    end

    def running?(executor)
      executor.success?('test', '-e', vmm_device)
    end

    def read_pid
      return nil unless File.exist?(pidfile)
      Integer(File.read(pidfile).strip)
    rescue StandardError
      nil
    end
  end
end
