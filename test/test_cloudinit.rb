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
    entry = VMCtl::VMEntry.new(name: 'pod35', config: 'pod.conf', network: 'labs',
                               link: 12, mac: nil, autostart: false, disks: [], cloud_init: nil)
    VMCtl::VM.new(entry, defaults)
  end

  def test_meta_data_has_instance_id_and_hostname
    md = VMCtl::CloudInit.new(FakeExecutor.new).meta_data_for('pod35')
    assert_match(/instance-id:\s*pod35/, md)
    assert_match(/local-hostname:\s*pod35/, md)
  end

  def test_render_user_data_substitutes_builtins_and_vars
    out = VMCtl::CloudInit.new(FakeExecutor.new).render_user_data(
      vm, "hostname: %(name)\nrole: %(role)\nnet: %(network)\n", 'role' => 'web'
    )
    assert_match(/^hostname: pod35$/, out)
    assert_match(/^role: web$/, out)
    assert_match(/^net: labs$/, out)
  end

  def test_render_user_data_vars_override_builtins
    out = VMCtl::CloudInit.new(FakeExecutor.new).render_user_data(vm, "n: %(name)\n", 'name' => 'override')
    assert_match(/^n: override$/, out)
  end

  def test_build_seed_reads_template_and_runs_makefs_to_vm_dir
    Dir.mktmpdir do |root|
      tmpl = File.join(root, 'tmpl.yml')
      File.write(tmpl, "#cloud-config\nhostname: %(name)\n")
      exec = FakeExecutor.new
      v = vm(dir: root)   # vm.dir need not exist: makefs is faked
      iso = VMCtl::CloudInit.new(exec).build_seed(v, tmpl, {})
      assert_equal File.join(v.dir, 'pod35-seed.iso'), iso
      cmd = exec.runs.find { |a| a.first == 'makefs' }
      refute_nil cmd, 'makefs must run'
      assert_includes cmd, iso
    end
  end
end
