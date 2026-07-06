# frozen_string_literal: true
# lib/vmctl/config_renderer.rb
require_relative 'substitution'

module VMCtl
  # Renders a VM's fully-resolved bhyve config from its base flavor file plus the
  # inventory entry. Pure: text/data in, config text out (no file writing).
  #
  # Layering (low -> high precedence):
  #   1. base flavor file, with %() substituted to concrete values
  #   2. per-VM options: map
  #   3. managed generated keys (disks today) -- always win
  class ConfigRenderer
    def initialize(defaults)
      @defaults = defaults
    end

    # vm: a VMCtl::VM. Returns the resolved config as a String.
    def render(vm)
      serialize(resolve(vm))
    end

    # Returns the fully merged/generated key map (before serialization):
    # flavor %()-substituted -> options: -> generators (generators win).
    def resolve(vm)
      # Read as binary: flavor comments may hold non-ASCII bytes and the host
      # may run under LANG=C; the scan/substitution must not raise on them.
      text = File.binread(vm.template_path)
      map = parse_pairs(substitute(text, vm.entry))
      stringify(vm.entry.options).each { |k, v| map[k] = v }
      generators.each { |gen| gen.call(vm).each { |k, v| map[k] = v } }
      map
    end

    # Serialize a resolved key map to bhyve_config text (sorted, k=v per line).
    def serialize(map)
      map.sort.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
    end

    private

    # Ordered managed-key generators, merged last so they always win. To promote
    # the net block / iso CD / cloud-init seed to generated wiring later, append a
    # generator here -- no other change is required.
    def generators
      [method(:disk_keys), method(:net_keys), method(:iso_cd_keys),
       method(:seed_cd_keys), method(:hardware_keys), method(:graphics_keys),
       method(:firmware_keys)]
    end

    # CPU/memory from the inventory (entry, falling back to defaults).
    def hardware_keys(vm)
      {
        'cpus'        => (vm.entry.cpus   || @defaults.cpus).to_s,
        'memory.size' => (vm.entry.memory || @defaults.memory).to_s
      }
    end

    # VNC framebuffer + USB tablet pointer, generated when graphics: true.
    # Port derives from the VM's (unique) link; bind address is a host default.
    def graphics_keys(vm)
      return {} unless vm.entry.graphics
      {
        'pci.0.7.0.device'        => 'fbuf',
        'pci.0.7.0.tcp'           => vm.vnc_endpoint,
        'pci.0.7.0.w'             => '1024',
        'pci.0.7.0.h'             => '768',
        'pci.0.7.0.wait'          => 'false',
        'pci.0.8.0.device'        => 'xhci',
        'pci.0.8.0.slot.1.device' => 'tablet'
      }
    end

    # Persistent UEFI variables store, generated when efi_vars: true. The file is
    # provisioned lazily at start (copied from the pristine host template).
    def firmware_keys(vm)
      return {} unless vm.entry.efi_vars
      { 'bootvars' => vm.uefi_vars_path }
    end

    def disk_keys(vm)
      keys = {}
      vm.entry.disks.each_with_index do |disk, n|
        keys["pci.0.3.#{n}.device"] = 'nvme'
        keys["pci.0.3.#{n}.path"]   = File.join(vm.dir, disk.file)
      end
      keys
    end

    def net_keys(vm)
      nics = nic_list(vm)
      keys = {}
      nics.each_with_index do |nic, f|
        p = "pci.0.4.#{f}"
        keys["#{p}.device"]   = 'virtio-net'
        keys["#{p}.backend"]  = 'netgraph'
        keys["#{p}.path"]     = "#{nic[:bridge]}:"
        keys["#{p}.peerhook"] = nic[:peerhook]
        keys["#{p}.socket"]   = nic[:socket]
        keys["#{p}.mtu"]      = (nic[:mtu] || 9000).to_s
        keys["#{p}.mac"]      = nic[:mac] if nic[:mac]
      end
      keys
    end

    # Installer ISO CD (read-only), generated when the VM has an iso:.
    def iso_cd_keys(vm)
      return {} unless vm.entry.iso
      {
        'pci.0.5.0.device'      => 'ahci',
        'pci.0.5.0.port.0.type' => 'cd',
        'pci.0.5.0.port.0.ro'   => 'true',
        'pci.0.5.0.port.0.path' => vm.entry.iso
      }
    end

    # NoCloud cloud-init seed CD, generated when the VM has cloud_init:.
    def seed_cd_keys(vm)
      return {} unless vm.entry.cloud_init
      {
        'pci.0.6.0.device'      => 'ahci',
        'pci.0.6.0.port.0.type' => 'cd',
        'pci.0.6.0.port.0.path' => File.join(vm.dir, "#{vm.name}-seed.iso")
      }
    end

    # Ordered NIC specs: primary (unless none/nil) then each additional NIC,
    # with role-based peerhook/socket names.
    def nic_list(vm)
      e = vm.entry
      list = []
      unless e.network.nil? || e.network == 'none'
        list << { bridge: e.network, mtu: e.mtu, mac: e.mac,
                  peerhook: "link#{e.link}", socket: "bhyve_#{vm.name}" }
      end
      (e.networks || []).each_with_index do |n, j|
        list << { bridge: n.bridge, mtu: n.mtu, mac: n.mac,
                  peerhook: "link#{e.link}_#{j + 1}", socket: "bhyve_#{vm.name}_#{j + 1}" }
      end
      list
    end

    def substitute(text, entry)
      VMCtl.substitute(text,
                       'name'    => entry.name.to_s,
                       'network' => entry.network.to_s,
                       'link'    => entry.link.to_s,
                       'mac'     => entry.mac.to_s,
                       'iso'     => entry.iso.to_s)
    end

    def parse_pairs(text)
      map = {}
      text.each_line do |line|
        s = line.strip
        next if s.empty? || s.start_with?('#')
        key, val = s.split('=', 2)
        next if val.nil?
        map[key.strip] = val.strip
      end
      map
    end

    def stringify(opts)
      (opts || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
    end
  end
end
