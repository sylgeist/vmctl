# frozen_string_literal: true
# lib/vmctl/provisioner.rb
require_relative 'sizes'

module VMCtl
  # Lays down a VM's ZFS dataset and raw disk image files. The create command
  # validates inputs (image exists, requested size not smaller than a clone
  # source) before calling here, so this stays mechanical.
  class Provisioner
    def initialize(executor, defaults)
      @exec = executor
      @defaults = defaults
    end

    def create_dataset(vm)
      @exec.run("zfs create #{@defaults.zpool}/#{vm.name}")
    end

    # Grow an existing raw disk in place. Caller validates new > current.
    def grow_disk(path, size)
      @exec.run("truncate -s #{size} #{path}")
    end

    # path: absolute target raw file. size: human size string. from: bare image
    # name (resolved via image_dir) or nil for a blank sparse file.
    def create_disk(path, size, from: nil)
      if from.nil?
        @exec.run("truncate -s #{size} #{path}")
        return
      end
      image = image_path(from)
      @exec.run("cp #{image} #{path}")
      grow_if_needed(path, size, image)
    end

    def image_path(from)
      return nil if from.nil?
      return from if from.start_with?('/')
      File.join(@defaults.image_dir, from)
    end

    private

    def grow_if_needed(path, size, image)
      return unless Sizes.parse(size) > File.size(image)
      @exec.run("truncate -s #{size} #{path}")
    end
  end
end
