# frozen_string_literal: true
# lib/vmctl/config.rb
require 'yaml'
require 'tempfile'
require_relative 'sizes'

module VMCtl
  class ConfigError < StandardError; end

  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from, :cpus, :memory, :vnc_base, :vnc_bind,
    keyword_init: true
  )
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options, :mtu, :networks, :cpus, :memory, :graphics,
    keyword_init: true
  )
  Nic = Struct.new(:bridge, :mtu, :mac, keyword_init: true)
  Disk = Struct.new(:file, :size, :from, keyword_init: true) do
    # spec grammar: "<suffix>:<size>[:from <image>]"
    #   e.g. "zfs:100G" or "data:50G:from gold.raw"
    def self.parse(name, spec)
      body, from = spec.to_s.split(':from ', 2)
      suffix, size = body.to_s.split(':', 2)
      if suffix.to_s.empty? || size.to_s.empty?
        raise ArgumentError, "invalid disk spec #{spec.inspect} (expected suffix:size)"
      end
      new(file: "#{name}-#{suffix}.raw", size: size, from: from)
    end
  end

  class Config
    DEFAULTS = {
      'config_dir' => '/bhyve/configs',
      'vm_root'    => '/bhyve',
      'zpool'      => 'tank/bhyve',
      'template'   => 'pod.conf',
      'link_base'  => 10,
      'run_dir'    => '/var/run/vmctl',
      'log_dir'    => '/var/log/vmctl',
      'image_dir'  => '/bhyve/images',
      'root_size'  => '20G',
      'root_from'  => nil,
      'cpus'       => 1,
      'memory'     => '1G',
      'vnc_base'   => 5900,
      'vnc_bind'   => '0.0.0.0'
    }.freeze

    attr_reader :defaults, :vms, :path

    def self.load(path)
      raise ConfigError, "Inventory file not found: #{path}" unless File.exist?(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      raise ConfigError, "Inventory must be a mapping in #{path}" unless raw.is_a?(Hash)
      new(raw, path)
    end

    def initialize(raw, path = nil)
      @path = path
      @defaults = parse_defaults(raw.fetch('defaults', {}) || {})
      @vms = parse_vms(raw.fetch('vms', {}) || {})
    end

    def save(path)
      dir = File.dirname(path)
      tmp = Tempfile.create(['inventory', '.yml'], dir)
      begin
        tmp.write(to_yaml)
        tmp.flush
        tmp.close
        File.rename(tmp.path, path)
      rescue StandardError
        File.delete(tmp.path) if File.exist?(tmp.path)
        raise
      end
    end

    def add_vm(entry)
      @vms[entry.name] = entry
    end

    def remove_vm(name)
      @vms.delete(name)
    end

    def to_h
      defaults_h = @defaults.to_h
      # Only include defaults that differ from DEFAULTS
      defaults_h = defaults_h.select { |k, v| DEFAULTS[k.to_s] != v }
      defaults_h = defaults_h.transform_keys(&:to_s)
      {
        'defaults' => defaults_h,
        'vms' => @vms.transform_values { |vm| vm_to_h(vm) }
      }
    end

    def to_yaml
      YAML.dump(to_h)
    end

    private

    def parse_defaults(h)
      merged = DEFAULTS.merge(h)
      Defaults.new(
        config_dir: merged['config_dir'],
        vm_root:    merged['vm_root'],
        zpool:      merged['zpool'],
        template:   merged['template'],
        link_base:  parse_link_base(merged['link_base']),
        run_dir:    merged['run_dir'],
        log_dir:    merged['log_dir'],
        image_dir:  merged['image_dir'],
        root_size:  merged['root_size'],
        root_from:  merged['root_from'],
        cpus:       parse_cpus(merged['cpus']),
        memory:     parse_memory(merged['memory']),
        vnc_base:   parse_vnc_base(merged['vnc_base']),
        vnc_bind:   merged['vnc_bind']
      )
    end

    def parse_vms(h)
      raise ConfigError, "'vms' must be a mapping" unless h.is_a?(Hash)
      h.each_with_object({}) do |(name, body), acc|
        acc[name] = parse_vm(name, body || {})
      end
    end

    def parse_vm(name, body)
      raise ConfigError, "VM '#{name}' must be a mapping" unless body.is_a?(Hash)
      VMEntry.new(
        name:       name,
        config:     body['config'] || @defaults.template,
        network:    body['network'],
        link:       body['link'],
        mac:        body['mac'],
        autostart:  body.fetch('autostart', false),
        disks:      parse_disks(body.fetch('disks', [])),
        cloud_init: parse_cloud_init(body['cloud_init']),
        iso:        body['iso'],
        options:    parse_options(body.fetch('options', {})),
        mtu:        body['mtu'],
        networks:   parse_networks(body.fetch('networks', [])),
        cpus:       parse_cpus(body['cpus']),
        memory:     parse_memory(body['memory']),
        graphics:   body.fetch('graphics', false)
      )
    end

    def parse_link_base(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ConfigError, "'link_base' must be an integer, got: #{value.inspect}"
    end

    def parse_vnc_base(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ConfigError, "'vnc_base' must be an integer, got: #{value.inspect}"
    end

    def parse_disks(list)
      raise ConfigError, "'disks' must be a list" unless list.is_a?(Array)
      list.map do |d|
        raise ConfigError, "each disk must be a mapping, got: #{d.inspect}" unless d.is_a?(Hash)
        Disk.new(file: d['file'], size: d['size'], from: d['from'])
      end
    end

    def parse_options(h)
      h ||= {}
      raise ConfigError, "'options' must be a mapping" unless h.is_a?(Hash)
      h
    end

    def parse_cpus(v)
      return nil if v.nil?
      n = Integer(v, exception: false)
      raise ConfigError, "'cpus' must be a positive integer, got: #{v.inspect}" if n.nil? || n <= 0
      n
    end

    def parse_memory(v)
      return nil if v.nil?
      Sizes.parse(v)   # validates format; raises ArgumentError on bad input
      v.to_s
    rescue ArgumentError
      raise ConfigError, "'memory' must be a size like 1G/512M, got: #{v.inspect}"
    end

    def parse_networks(list)
      list ||= []
      raise ConfigError, "'networks' must be a list" unless list.is_a?(Array)
      list.map do |n|
        raise ConfigError, "each network must be a mapping, got: #{n.inspect}" unless n.is_a?(Hash)
        bridge = n['bridge']
        raise ConfigError, "each network needs a 'bridge', got: #{n.inspect}" if bridge.to_s.empty?
        Nic.new(bridge: bridge, mtu: n['mtu'], mac: n['mac'])
      end
    end

    def parse_cloud_init(ci)
      return nil if ci.nil?
      raise ConfigError, "'cloud_init' must be a mapping" unless ci.is_a?(Hash)
      if ci['user_data'].to_s.empty?
        raise ConfigError, "'cloud_init' needs a 'user_data' template"
      end
      vars = ci['vars']
      raise ConfigError, "'cloud_init.vars' must be a mapping" unless vars.nil? || vars.is_a?(Hash)
      ci
    end

    def vm_to_h(vm)
      h = {
        'config'  => vm.config,
        'network' => vm.network,
        'link'    => vm.link,
        'mac'     => vm.mac,
        'autostart' => vm.autostart,
        'disks'   => vm.disks.map { |d| compact_disk(d) }
      }
      h['cloud_init'] = vm.cloud_init if vm.cloud_init
      h['iso'] = vm.iso if vm.iso
      h['options'] = vm.options unless vm.options.nil? || vm.options.empty?
      h['cpus'] = vm.cpus unless vm.cpus.nil?
      h['memory'] = vm.memory unless vm.memory.nil?
      h['graphics'] = true if vm.graphics
      h['mtu'] = vm.mtu unless vm.mtu.nil?
      h['networks'] = vm.networks.map { |n| compact_nic(n) } unless vm.networks.nil? || vm.networks.empty?
      h
    end

    def compact_disk(d)
      h = { 'file' => d.file, 'size' => d.size }
      h['from'] = d.from if d.from
      h
    end

    def compact_nic(n)
      h = { 'bridge' => n.bridge }
      h['mtu'] = n.mtu unless n.mtu.nil?
      h['mac'] = n.mac unless n.mac.nil?
      h
    end
  end
end
