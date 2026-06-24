# frozen_string_literal: true
# lib/vmctl/config_renderer.rb
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
      # Read as binary: flavor comments may hold non-ASCII bytes and the host
      # may run under LANG=C; the scan/substitution must not raise on them.
      text = File.binread(vm.template_path)
      map = parse_pairs(substitute(text, vm.entry))
      stringify(vm.entry.options).each { |k, v| map[k] = v }
      generators.each { |gen| gen.call(vm).each { |k, v| map[k] = v } }
      map.sort.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
    end

    private

    # Ordered managed-key generators, merged last so they always win. To promote
    # the net block / iso CD / cloud-init seed to generated wiring later, append a
    # generator here -- no other change is required.
    def generators
      [method(:disk_keys)]
    end

    def disk_keys(vm)
      keys = {}
      vm.entry.disks.each_with_index do |disk, n|
        keys["pci.0.3.#{n}.device"] = 'nvme'
        keys["pci.0.3.#{n}.path"]   = File.join(vm.dir, disk.file)
      end
      keys
    end

    def substitute(text, entry)
      vars = {
        'name'    => entry.name.to_s,
        'network' => entry.network.to_s,
        'link'    => entry.link.to_s,
        'mac'     => entry.mac.to_s,
        'iso'     => entry.iso.to_s
      }
      text.gsub(/%\((\w+)\)/) { vars.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
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
