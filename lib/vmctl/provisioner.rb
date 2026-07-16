# frozen_string_literal: true
# lib/vmctl/provisioner.rb
require_relative 'sizes'

module VMCtl
  # Lays down a VM's ZFS dataset and raw disk image files. The create command
  # validates inputs (image exists, requested size not smaller than a clone
  # source) before calling here, so this stays mechanical.
  class Provisioner
    SNAP_PREFIX = 'vmctl-clone-'

    def initialize(executor, defaults)
      @exec = executor
      @defaults = defaults
    end

    def create_dataset(vm)
      @exec.run('zfs', 'create', "#{@defaults.zpool}/#{vm.name}")
    end

    # Grow an existing raw disk in place. Caller validates new > current.
    def grow_disk(path, size)
      @exec.run('truncate', '-s', size, path)
    end

    # path: absolute target raw file. size: human size string. from: bare image
    # name (resolved via image_dir) or nil for a blank sparse file.
    def create_disk(path, size, from: nil)
      if from.nil?
        @exec.run('truncate', '-s', size, path)
        return
      end
      image = image_path(from)
      @exec.run('cp', image, path)
      grow_if_needed(path, size, image)
    end

    def image_path(from)
      return nil if from.nil?
      return from if from.start_with?('/')
      File.join(@defaults.image_dir, from)
    end

    # Full independent copy of source_vm's dataset into dest_vm's, via
    # snapshot + send|recv. Renames disk files to the dest's name prefix, drops
    # the copied UEFI vars store, and removes both snapshots. Rolls back the
    # received dataset on failure.
    def clone_dataset(source_vm, dest_vm)
      snap = "#{@defaults.zpool}/#{source_vm.name}@#{SNAP_PREFIX}#{dest_vm.name}"
      dest_ds = "#{@defaults.zpool}/#{dest_vm.name}"
      @exec.run('zfs', 'snapshot', snap)
      begin
        @exec.pipe(['zfs', 'send', snap], ['zfs', 'recv', dest_ds])
        rename_clone_disks(source_vm, dest_vm)
        @exec.run('rm', '-f', File.join(dest_vm.dir, "#{source_vm.name}-uefi-vars.fd"))
        @exec.run('rm', '-f', File.join(dest_vm.dir, "#{source_vm.name}-seed.iso"))
      rescue StandardError
        destroy_quietly(dest_ds)
        destroy_quietly(snap)
        raise
      end
      destroy_quietly(snap)
      destroy_quietly("#{dest_ds}@#{SNAP_PREFIX}#{dest_vm.name}")
      nil
    end

    private

    def grow_if_needed(path, size, image)
      return unless Sizes.parse(size) > File.size(image)
      @exec.run('truncate', '-s', size, path)
    end

    def rename_clone_disks(source_vm, dest_vm)
      source_vm.entry.disks.zip(dest_vm.entry.disks).each do |src_disk, dst_disk|
        next if src_disk.file == dst_disk.file
        @exec.run('mv',
                  File.join(dest_vm.dir, src_disk.file),
                  File.join(dest_vm.dir, dst_disk.file))
      end
    end

    def destroy_quietly(target)
      @exec.run('zfs', 'destroy', target)
    rescue ExecutorError
      nil
    end
  end
end
