# frozen_string_literal: true
# test/test_vm.rb
require 'test_helper'
require 'tmpdir'
require 'fileutils'
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

  def entry(mac: nil, iso: nil, config: 'pod.conf', network: 'labs_vlan50', networks: [])
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: network, link: 10,
      mac: mac, autostart: true,
      disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)],
      cloud_init: nil, iso: iso, networks: networks
    )
  end

  def test_config_path_in_run_dir
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal '/var/run/vmctl/pod34.conf', vm.config_path
  end

  def test_bhyve_argv_references_ephemeral_config
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal(['bhyve', '-k', '/var/run/vmctl/pod34.conf', 'pod34'], vm.bhyve_argv)
  end

  def test_bhyve_command_is_joined_string
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal 'bhyve -k /var/run/vmctl/pod34.conf pod34', vm.bhyve_command
  end

  def test_render_and_write_config
    Dir.mktmpdir do |dir|
      cfgdir = File.join(dir, 'configs'); FileUtils.mkdir_p(cfgdir)
      File.write(File.join(cfgdir, 'pod.conf'),
                 "cpus=2\nlpc.com1.path=/dev/nmdm%(link)A\n")
      run = File.join(dir, 'run')
      d = VMCtl::Defaults.new(
        config_dir: cfgdir, vm_root: '/bhyve', zpool: 'tank/bhyve',
        template: 'pod.conf', link_base: 10, run_dir: run, log_dir: '/l'
      )
      vm = VMCtl::VM.new(entry, d)
      text = vm.render_config
      assert_match(/^cpus=2$/, text)
      assert_match(%r{^lpc\.com1\.path=/dev/nmdm10A$}, text)
      assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, text)
      path = vm.write_config
      assert_equal File.join(run, 'pod34.conf'), path
      assert_equal text, File.binread(path)
    end
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

  def test_nic_bridges_and_count_primary_only
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal ['labs_vlan50'], vm.nic_bridges
    assert_equal 1, vm.nic_count
  end

  def test_nic_bridges_and_count_with_networks
    nets = [VMCtl::Nic.new(bridge: 'b1', mtu: nil, mac: nil),
            VMCtl::Nic.new(bridge: 'b2', mtu: nil, mac: nil)]
    vm = VMCtl::VM.new(entry(networks: nets), defaults)
    assert_equal %w[labs_vlan50 b1 b2], vm.nic_bridges
    assert_equal 3, vm.nic_count
  end

  def test_nic_bridges_and_count_network_none
    vm = VMCtl::VM.new(entry(network: 'none'), defaults)
    assert_equal [], vm.nic_bridges
    assert_equal 0, vm.nic_count
  end
end
