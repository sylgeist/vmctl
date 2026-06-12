# frozen_string_literal: true
# test/test_vm.rb
require 'test_helper'
require 'tmpdir'
require 'vmctl/config'
require 'vmctl/vm'

class TestVM < Minitest::Test
  def defaults(config_dir: '/bhyve/configs')
    VMCtl::Defaults.new(
      config_dir: config_dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
    )
  end

  def entry(mac: nil, iso: nil, config: 'pod.conf')
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: 'labs_vlan50', link: 10,
      mac: mac, autostart: true,
      disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)],
      cloud_init: nil, iso: iso
    )
  end

  def test_bhyve_argv_without_mac
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(
      ['bhyve', '-k', '/bhyve/configs/pod.conf',
       '-o', 'network=labs_vlan50', '-o', 'link=10', 'pod34'],
      vm.bhyve_argv
    )
  end

  def test_bhyve_argv_includes_mac_when_set
    vm = VMCtl::VM.new(entry(mac: '5a:9c:fc:01:02:03'), defaults)
    assert_includes vm.bhyve_argv, 'mac=5a:9c:fc:01:02:03'
  end

  def test_bhyve_command_is_joined_string
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(
      'bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 pod34',
      vm.bhyve_command
    )
  end

  def test_paths
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal '/bhyve/pod34', vm.dir
    assert_equal '/var/run/vmctl/pod34.pid', vm.pidfile
    assert_equal '/var/log/vmctl/pod34.log', vm.logfile
    assert_equal '/dev/vmm/pod34', vm.vmm_device
    assert_equal '/dev/nmdm10B', vm.console_device
    assert_equal ['/bhyve/pod34/pod34-root.raw'], vm.disk_paths
  end

  def test_dump_command_inserts_config_dump_before_name
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(
      'bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 ' \
      '-o config.dump=1 pod34',
      vm.dump_command
    )
  end

  def test_dump_command_with_mac_keeps_order
    vm = VMCtl::VM.new(entry(mac: '5a:9c:fc:01:02:03'), defaults)
    assert_equal(
      'bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 ' \
      '-o mac=5a:9c:fc:01:02:03 -o config.dump=1 pod34',
      vm.dump_command
    )
  end

  def test_bhyve_argv_includes_iso_when_set
    vm = VMCtl::VM.new(entry(iso: '/bhyve/isos/install.iso'), defaults)
    assert_includes vm.bhyve_argv, 'iso=/bhyve/isos/install.iso'
  end

  def test_bhyve_argv_omits_iso_when_nil
    vm = VMCtl::VM.new(entry, defaults)
    refute(vm.bhyve_argv.any? { |a| a.start_with?('iso=') })
  end

  def test_dump_command_includes_iso_when_set
    vm = VMCtl::VM.new(entry(iso: '/bhyve/isos/install.iso'), defaults)
    assert_includes vm.dump_command, '-o iso=/bhyve/isos/install.iso'
  end

  def test_template_wants_iso_detects_reference
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'inst.conf'), "pci.0.5.0.port.0.path=%(iso)\n")
      vm = VMCtl::VM.new(entry(config: 'inst.conf'), defaults(config_dir: dir))
      assert vm.template_wants_iso?
    end
  end

  def test_template_wants_iso_false_when_absent
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'plain.conf'), "cpus=2\n")
      vm = VMCtl::VM.new(entry(config: 'plain.conf'), defaults(config_dir: dir))
      refute vm.template_wants_iso?
    end
  end

  def test_template_wants_iso_ignores_commented_lines
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'c.conf'), "cpus=2\n#pci.0.5.0.port.0.path=%(iso)\n")
      vm = VMCtl::VM.new(entry(config: 'c.conf'), defaults(config_dir: dir))
      refute vm.template_wants_iso?
    end
  end

  def test_template_wants_iso_false_when_template_missing
    vm = VMCtl::VM.new(entry(config: 'nope.conf'), defaults)
    refute vm.template_wants_iso?
  end
end
