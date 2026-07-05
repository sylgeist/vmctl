# frozen_string_literal: true
# lib/vmctl/cloudinit.rb
require 'tmpdir'
require 'fileutils'

module VMCtl
  # Builds a NoCloud cloud-init seed ISO: generated meta-data + the operator's
  # verbatim user-data, packed with makefs as an ISO9660 volume labelled cidata.
  class CloudInit
    def initialize(executor)
      @exec = executor
    end

    def meta_data_for(name)
      "instance-id: #{name}\nlocal-hostname: #{name}\n"
    end

    def populate_seed(seeddir, vm, user_data_path)
      File.write(File.join(seeddir, 'meta-data'), meta_data_for(vm.name))
      FileUtils.cp(user_data_path, File.join(seeddir, 'user-data'))
    end

    # Returns the ISO path (<vm.dir>/<name>-seed.iso).
    def build_seed(vm, user_data_path)
      iso = File.join(vm.dir, "#{vm.name}-seed.iso")
      Dir.mktmpdir('vmctl-seed') do |seeddir|
        populate_seed(seeddir, vm, user_data_path)
        @exec.run('makefs', '-t', 'cd9660', '-o', 'rockridge,label=cidata', iso, seeddir)
      end
      iso
    end
  end
end
