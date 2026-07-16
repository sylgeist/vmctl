# frozen_string_literal: true
# test/test_provisioner.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/provisioner'
require 'tmpdir'

class TestProvisioner < Minitest::Test
  def defaults(image_dir: '/bhyve/images')
    VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10, run_dir: '/var/run/vmctl',
      log_dir: '/var/log/vmctl', image_dir: image_dir, root_size: '20G', root_from: nil
    )
  end

  def vm
    entry = VMCtl::VMEntry.new(name: 'pod35', config: 'pod.conf', network: 'n',
                               link: 12, mac: nil, autostart: false, disks: [], cloud_init: nil)
    VMCtl::VM.new(entry, defaults)
  end

  def test_create_dataset
    exec = FakeExecutor.new
    VMCtl::Provisioner.new(exec, defaults).create_dataset(vm)
    assert_includes exec.runs, ['zfs', 'create', 'tank/bhyve/pod35']
  end

  def test_create_blank_disk_uses_truncate
    exec = FakeExecutor.new
    VMCtl::Provisioner.new(exec, defaults).create_disk('/bhyve/pod35/pod35-zfs.raw', '100G', from: nil)
    assert_includes exec.runs, ['truncate', '-s', '100G', '/bhyve/pod35/pod35-zfs.raw']
  end

  def test_image_path_resolves_relative_to_image_dir
    p = VMCtl::Provisioner.new(FakeExecutor.new, defaults(image_dir: '/img'))
    assert_equal '/img/base.raw', p.image_path('base.raw')
    assert_equal '/abs/base.raw', p.image_path('/abs/base.raw')
    assert_nil p.image_path(nil)
  end

  def test_clone_grows_when_requested_larger
    dir = Dir.mktmpdir
    img = File.join(dir, 'base.raw')
    File.write(img, 'x' * 1024) # 1K source
    exec = FakeExecutor.new
    p = VMCtl::Provisioner.new(exec, defaults(image_dir: dir))
    p.create_disk('/bhyve/pod35/pod35-root.raw', '1M', from: 'base.raw')
    assert_includes exec.runs, ['cp', img, '/bhyve/pod35/pod35-root.raw']
    assert_includes exec.runs, ['truncate', '-s', '1M', '/bhyve/pod35/pod35-root.raw']
  end

  def test_clone_skips_truncate_when_size_equals_source
    dir = Dir.mktmpdir
    img = File.join(dir, 'base.raw')
    File.write(img, 'x' * 1024) # exactly 1K
    exec = FakeExecutor.new
    p = VMCtl::Provisioner.new(exec, defaults(image_dir: dir))
    p.create_disk('/bhyve/pod35/pod35-root.raw', '1K', from: 'base.raw')
    assert_includes exec.runs, ['cp', img, '/bhyve/pod35/pod35-root.raw']
    refute(exec.runs.any? { |a| a.first == 'truncate' }, 'no grow when size == source')
  end

  def test_grow_disk_runs_truncate
    exec = FakeExecutor.new
    prov = VMCtl::Provisioner.new(exec, nil)
    prov.grow_disk('/bhyve/pod34/pod34-data.raw', '100G')
    assert_includes exec.runs, ['truncate', '-s', '100G', '/bhyve/pod34/pod34-data.raw']
  end

  def clone_defaults
    VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10, run_dir: '/var/run/vmctl',
      log_dir: '/var/log/vmctl', image_dir: '/bhyve/images', root_size: '20G', root_from: nil
    )
  end

  def clone_vm(name, files)
    disks = files.map { |f| VMCtl::Disk.new(file: f, size: '1G', from: nil) }
    entry = VMCtl::VMEntry.new(name: name, config: 'pod.conf', network: 'n',
                               link: 12, mac: nil, autostart: false, disks: disks, cloud_init: nil)
    VMCtl::VM.new(entry, clone_defaults)
  end

  def test_clone_dataset_emits_snapshot_send_recv_rename_and_cleanup
    exec = FakeExecutor.new
    src = clone_vm('pod34', ['pod34-root.raw'])
    dst = clone_vm('web1',  ['web1-root.raw'])
    VMCtl::Provisioner.new(exec, clone_defaults).clone_dataset(src, dst)

    assert_includes exec.runs, ['zfs', 'snapshot', 'tank/bhyve/pod34@vmctl-clone-web1']
    assert_includes exec.pipes,
                    [['zfs', 'send', 'tank/bhyve/pod34@vmctl-clone-web1'],
                     ['zfs', 'recv', 'tank/bhyve/web1']]
    assert_includes exec.runs, ['mv', '/bhyve/web1/pod34-root.raw', '/bhyve/web1/web1-root.raw']
    assert_includes exec.runs, ['rm', '-f', '/bhyve/web1/pod34-uefi-vars.fd']
    assert_includes exec.runs, ['zfs', 'destroy', 'tank/bhyve/pod34@vmctl-clone-web1']
    assert_includes exec.runs, ['zfs', 'destroy', 'tank/bhyve/web1@vmctl-clone-web1']
  end

  def test_clone_dataset_skips_mv_when_disk_name_unchanged
    # An oddly-named (non-<src>- prefixed) disk keeps its name: no mv for it.
    exec = FakeExecutor.new
    src = clone_vm('pod34', ['data.raw'])
    dst = clone_vm('web1',  ['data.raw'])
    VMCtl::Provisioner.new(exec, clone_defaults).clone_dataset(src, dst)
    refute(exec.runs.any? { |a| a.first == 'mv' }, 'unchanged disk name must not be moved')
  end
end
