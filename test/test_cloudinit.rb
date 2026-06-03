# frozen_string_literal: true
# test/test_cloudinit.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/cloudinit'
require 'tmpdir'

class TestCloudInit < Minitest::Test
  def vm(dir: '/bhyve')
    defaults = VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: dir, zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10, run_dir: '/var/run/vmctl',
      log_dir: '/var/log/vmctl', image_dir: '/bhyve/images', root_size: '20G', root_from: nil
    )
    entry = VMCtl::VMEntry.new(name: 'pod35', config: 'pod.conf', network: 'n',
                               link: 12, mac: nil, autostart: false, disks: [], cloud_init: nil)
    VMCtl::VM.new(entry, defaults)
  end

  def test_meta_data_has_instance_id_and_hostname
    md = VMCtl::CloudInit.new(FakeExecutor.new).meta_data_for('pod35')
    assert_match(/instance-id:\s*pod35/, md)
    assert_match(/local-hostname:\s*pod35/, md)
  end

  def test_populate_seed_writes_meta_and_user_data
    seeddir = Dir.mktmpdir
    ud = File.join(Dir.mktmpdir, 'ud.yml')
    File.write(ud, "#cloud-config\nusers: []\n")
    VMCtl::CloudInit.new(FakeExecutor.new).populate_seed(seeddir, vm, ud)
    assert_match(/instance-id:\s*pod35/, File.read(File.join(seeddir, 'meta-data')))
    assert_equal "#cloud-config\nusers: []\n", File.read(File.join(seeddir, 'user-data'))
  end

  def test_build_seed_runs_makefs_to_vm_dir
    vmdir = Dir.mktmpdir
    v = vm(dir: vmdir) # vm.dir == <vmdir>/pod35
    FileUtils.mkdir_p(v.dir)
    ud = File.join(Dir.mktmpdir, 'ud.yml')
    File.write(ud, "#cloud-config\n")
    exec = FakeExecutor.new
    iso = VMCtl::CloudInit.new(exec).build_seed(v, ud)
    expected_iso = File.join(v.dir, 'pod35-seed.iso')
    assert_equal expected_iso, iso
    cmd = exec.runs.find { |c| c.start_with?('makefs') }
    refute_nil cmd, 'makefs must run'
    assert_match(/makefs -t cd9660 -o rockridge,label=cidata #{Regexp.escape(expected_iso)} /, cmd)
  end
end
