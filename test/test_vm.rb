# frozen_string_literal: true
# test/test_vm.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'

class TestVM < Minitest::Test
  def defaults
    VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
    )
  end

  def entry(mac: nil)
    VMCtl::VMEntry.new(
      name: 'pod34', config: 'pod.conf', network: 'labs_vlan50', link: 10,
      mac: mac, autostart: true,
      disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)],
      cloud_init: nil
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
end
