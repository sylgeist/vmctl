# frozen_string_literal: true
# lib/vmctl/cloudinit.rb
require 'tmpdir'
require_relative 'substitution'

module VMCtl
  # Builds a NoCloud cloud-init seed ISO: generated meta-data + rendered user-data
  # (template with %() substitutions), packed with makefs as an ISO9660 volume
  # labelled cidata.
  class CloudInit
    def initialize(executor)
      @exec = executor
    end

    def meta_data_for(name)
      "instance-id: #{name}\nlocal-hostname: #{name}\n"
    end

    # Renders user-data (built-ins + vars) and packs a NoCloud seed ISO.
    # Returns the ISO path (<vm.dir>/<name>-seed.iso).
    def build_seed(vm, template_path, vars = {})
      rendered = render_user_data(vm, File.read(template_path), vars)
      iso = File.join(vm.dir, "#{vm.name}-seed.iso")
      Dir.mktmpdir('vmctl-seed') do |seeddir|
        File.write(File.join(seeddir, 'meta-data'), meta_data_for(vm.name))
        File.write(File.join(seeddir, 'user-data'), rendered)
        @exec.run('makefs', '-t', 'cd9660', '-o', 'rockridge,label=cidata', iso, seeddir)
      end
      iso
    end

    # Public + pure: substitutes %() from built-ins (name/network/link/mac) plus
    # the operator vars (vars win). The testable seam.
    def render_user_data(vm, text, vars)
      e = vm.entry
      builtins = { 'name' => vm.name, 'network' => e.network.to_s,
                   'link' => e.link.to_s, 'mac' => e.mac.to_s }
      VMCtl.substitute(text, builtins.merge(stringify(vars)))
    end

    private

    def stringify(vars)
      (vars || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
    end
  end
end
