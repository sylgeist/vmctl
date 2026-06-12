# frozen_string_literal: true
# lib/vmctl/config.rb
require 'yaml'
require 'tempfile'

module VMCtl
  class ConfigError < StandardError; end

  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from,
    keyword_init: true
  )
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    keyword_init: true
  )
  Disk = Struct.new(:file, :size, :from, keyword_init: true)

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
      'root_from'  => nil
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
      {
        'defaults' => @defaults.to_h.transform_keys(&:to_s),
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
        root_from:  merged['root_from']
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
        cloud_init: body['cloud_init'],
        iso:        body['iso']
      )
    end

    def parse_link_base(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ConfigError, "'link_base' must be an integer, got: #{value.inspect}"
    end

    def parse_disks(list)
      raise ConfigError, "'disks' must be a list" unless list.is_a?(Array)
      list.map do |d|
        raise ConfigError, "each disk must be a mapping, got: #{d.inspect}" unless d.is_a?(Hash)
        Disk.new(file: d['file'], size: d['size'], from: d['from'])
      end
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
      h
    end

    def compact_disk(d)
      h = { 'file' => d.file, 'size' => d.size }
      h['from'] = d.from if d.from
      h
    end
  end
end
