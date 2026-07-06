# frozen_string_literal: true
# test/test_config_renderer.rb
require 'test_helper'
require 'tmpdir'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/config_renderer'

class TestConfigRenderer < Minitest::Test
  def defaults(config_dir)
    VMCtl::Defaults.new(
      config_dir: config_dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'base.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl',
      cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0'
    )
  end

  def entry(disks:, mac: nil, iso: nil, cloud_init: nil, options: {}, config: 'base.conf',
            network: 'labs_vlan50', mtu: nil, networks: [], cpus: nil, memory: nil,
            graphics: false)
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: network, link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: cloud_init, iso: iso,
      options: options, mtu: mtu, networks: networks, cpus: cpus, memory: memory,
      graphics: graphics
    )
  end

  def render(flavor_body, e)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, e.config), flavor_body)
      vm = VMCtl::VM.new(e, defaults(dir))
      return VMCtl::ConfigRenderer.new(defaults(dir)).render(vm)
    end
  end

  def test_substitutes_placeholders
    out = render("lpc.com1.path=/dev/nmdm%(link)A\nnet=%(network)\n",
                 entry(disks: []))
    assert_match(%r{^lpc\.com1\.path=/dev/nmdm10A$}, out)
    assert_match(/^net=labs_vlan50$/, out)
  end

  def test_generates_disk_slots
    e = entry(disks: [
      VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil),
      VMCtl::Disk.new(file: 'pod34-data.raw', size: '50G', from: nil)
    ])
    out = render("cpus=2\n", e)
    assert_match(/^pci\.0\.3\.0\.device=nvme$/, out)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(/^pci\.0\.3\.1\.device=nvme$/, out)
    assert_match(%r{^pci\.0\.3\.1\.path=/bhyve/pod34/pod34-data\.raw$}, out)
  end

  def test_no_disks_no_disk_keys
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.3\./, out)
  end

  def test_eight_disks
    disks = (0...8).map { |i| VMCtl::Disk.new(file: "pod34-d#{i}.raw", size: '1G', from: nil) }
    out = render("cpus=2\n", entry(disks: disks))
    assert_match(/^pci\.0\.3\.7\.device=nvme$/, out)
  end

  def test_options_override_base
    out = render("custom=2\n", entry(disks: [], options: { 'custom' => 4 }))
    assert_match(/^custom=4$/, out)
    refute_match(/^custom=2$/, out)
  end

  def test_managed_disk_keys_beat_options
    e = entry(disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)],
              options: { 'pci.0.3.0.path' => '/evil' })
    out = render("cpus=2\n", e)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, out)
    refute_match(%r{/evil}, out)
  end

  def test_comments_and_blank_lines_dropped
    out = render("# a comment\n\ncpus=2\n", entry(disks: []))
    refute_match(/comment/, out)
    assert_match(/^cpus=1$/, out)
  end

  def test_output_is_sorted
    out = render("zeta=1\nalpha=2\n", entry(disks: [], network: 'none'))
    assert_equal %w[alpha=2 cpus=1 memory.size=1G zeta=1], out.split("\n")
  end

  def test_iso_substituted_when_set
    out = render("pci.0.5.0.port.0.path=%(iso)\n",
                 entry(disks: [], iso: '/iso/x.iso'))
    assert_match(%r{^pci\.0\.5\.0\.port\.0\.path=/iso/x\.iso$}, out)
  end

  def test_tolerates_non_ascii_bytes_in_comments
    body = +"# notes \xFF \xE2\x80\x94 bytes\n".b
    body << "cpus=2\n"
    out = render(body, entry(disks: []))
    assert_match(/^cpus=1$/, out)
  end

  def test_primary_nic_matches_legacy_keys
    out = render("cpus=2\n", entry(disks: []))
    assert_match(/^pci\.0\.4\.0\.device=virtio-net$/, out)
    assert_match(/^pci\.0\.4\.0\.backend=netgraph$/, out)
    assert_match(/^pci\.0\.4\.0\.path=labs_vlan50:$/, out)
    assert_match(/^pci\.0\.4\.0\.peerhook=link10$/, out)
    assert_match(/^pci\.0\.4\.0\.socket=bhyve_pod34$/, out)
    assert_match(/^pci\.0\.4\.0\.mtu=9000$/, out)
    refute_match(/^pci\.0\.4\.0\.mac=/, out)   # no mac when unset
  end

  def test_primary_mac_and_mtu_override
    out = render("cpus=2\n", entry(disks: [], mac: '5a:9c:fc:00:00:11', mtu: 1500))
    assert_match(/^pci\.0\.4\.0\.mac=5a:9c:fc:00:00:11$/, out)
    assert_match(/^pci\.0\.4\.0\.mtu=1500$/, out)
  end

  def test_additional_nics_get_sequential_functions_and_roles
    nets = [VMCtl::Nic.new(bridge: 'storage_vlan60', mtu: nil, mac: nil),
            VMCtl::Nic.new(bridge: 'mgmt_vlan70', mtu: 1500, mac: '5a:9c:fc:00:00:21')]
    out = render("cpus=2\n", entry(disks: [], networks: nets))
    # nic 1
    assert_match(/^pci\.0\.4\.1\.path=storage_vlan60:$/, out)
    assert_match(/^pci\.0\.4\.1\.peerhook=link10_1$/, out)
    assert_match(/^pci\.0\.4\.1\.socket=bhyve_pod34_1$/, out)
    assert_match(/^pci\.0\.4\.1\.mtu=9000$/, out)
    refute_match(/^pci\.0\.4\.1\.mac=/, out)
    # nic 2
    assert_match(/^pci\.0\.4\.2\.path=mgmt_vlan70:$/, out)
    assert_match(/^pci\.0\.4\.2\.peerhook=link10_2$/, out)
    assert_match(/^pci\.0\.4\.2\.socket=bhyve_pod34_2$/, out)
    assert_match(/^pci\.0\.4\.2\.mtu=1500$/, out)
    assert_match(/^pci\.0\.4\.2\.mac=5a:9c:fc:00:00:21$/, out)
  end

  def test_network_none_omits_primary_and_shifts_functions
    nets = [VMCtl::Nic.new(bridge: 'storage_vlan60', mtu: nil, mac: nil)]
    out = render("cpus=2\n", entry(disks: [], network: 'none', networks: nets))
    # the sole additional NIC takes function 0 (no gap), keeps its role-based name
    assert_match(/^pci\.0\.4\.0\.path=storage_vlan60:$/, out)
    assert_match(/^pci\.0\.4\.0\.peerhook=link10_1$/, out)
    assert_match(/^pci\.0\.4\.0\.socket=bhyve_pod34_1$/, out)
    refute_match(/^pci\.0\.4\.1\./, out)
  end

  def test_network_none_no_networks_has_no_nics
    out = render("cpus=2\n", entry(disks: [], network: 'none'))
    refute_match(/^pci\.0\.4\./, out)
  end

  def test_iso_cd_generated_when_iso_set
    out = render("cpus=2\n", entry(disks: [], iso: '/bhyve/isos/x.iso'))
    assert_match(/^pci\.0\.5\.0\.device=ahci$/, out)
    assert_match(/^pci\.0\.5\.0\.port\.0\.type=cd$/, out)
    assert_match(/^pci\.0\.5\.0\.port\.0\.ro=true$/, out)
    assert_match(%r{^pci\.0\.5\.0\.port\.0\.path=/bhyve/isos/x\.iso$}, out)
  end

  def test_no_iso_cd_when_absent
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.5\./, out)
  end

  def test_seed_cd_generated_when_cloud_init_set
    out = render("cpus=2\n", entry(disks: [], cloud_init: { 'user_data' => 'x.yml' }))
    assert_match(/^pci\.0\.6\.0\.device=ahci$/, out)
    assert_match(/^pci\.0\.6\.0\.port\.0\.type=cd$/, out)
    assert_match(%r{^pci\.0\.6\.0\.port\.0\.path=/bhyve/pod34/pod34-seed\.iso$}, out)
    refute_match(/^pci\.0\.6\.0\.port\.0\.ro=/, out)   # seed CD is read-write
  end

  def test_no_seed_cd_when_absent
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.6\./, out)
  end

  def test_iso_and_seed_cds_coexist
    out = render("cpus=2\n", entry(disks: [], iso: '/i.iso', cloud_init: { 'user_data' => 'x.yml' }))
    assert_match(/^pci\.0\.5\.0\.device=ahci$/, out)
    assert_match(/^pci\.0\.6\.0\.device=ahci$/, out)
  end

  def test_hardware_from_entry
    out = render("cpus=99\nmemory.size=99G\n", entry(disks: [], cpus: 2, memory: '4G'))
    assert_match(/^cpus=2$/, out)
    assert_match(/^memory\.size=4G$/, out)
    refute_match(/^cpus=99$/, out)          # generated overrides the flavor
    refute_match(/^memory\.size=99G$/, out)
  end

  def test_hardware_falls_back_to_defaults
    out = render("cpus=99\n", entry(disks: []))   # entry cpus/memory nil
    assert_match(/^cpus=1$/, out)                 # defaults(dir) -> cpus 1
    assert_match(/^memory\.size=1G$/, out)
  end

  def test_hardware_overrides_options
    out = render("cpus=2\n", entry(disks: [], cpus: 8, options: { 'cpus' => 5 }))
    assert_match(/^cpus=8$/, out)                 # generated beats options
    refute_match(/^cpus=5$/, out)
  end

  def test_no_graphics_keys_when_disabled
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.7\./, out)
    refute_match(/pci\.0\.8\./, out)
  end

  def test_graphics_generates_fbuf_and_tablet
    out = render("cpus=2\n", entry(disks: [], graphics: true))
    assert_match(/^pci\.0\.7\.0\.device=fbuf$/, out)
    assert_match(/^pci\.0\.7\.0\.tcp=0\.0\.0\.0:5910$/, out)   # vnc_base 5900 + link 10
    assert_match(/^pci\.0\.7\.0\.w=1024$/, out)
    assert_match(/^pci\.0\.7\.0\.h=768$/, out)
    assert_match(/^pci\.0\.7\.0\.wait=false$/, out)
    assert_match(/^pci\.0\.8\.0\.device=xhci$/, out)
    assert_match(/^pci\.0\.8\.0\.slot\.1\.device=tablet$/, out)
  end

  def test_graphics_port_tracks_bind_from_defaults
    # Render with a loopback bind + custom base to prove the endpoint is data-driven.
    Dir.mktmpdir do |dir|
      e = entry(disks: [], graphics: true)
      File.write(File.join(dir, e.config), "cpus=2\n")
      d = VMCtl::Defaults.new(
        config_dir: dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
        template: 'base.conf', link_base: 10,
        run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl',
        cpus: 1, memory: '1G', vnc_base: 6000, vnc_bind: '127.0.0.1'
      )
      vm = VMCtl::VM.new(e, d)
      out = VMCtl::ConfigRenderer.new(d).render(vm)
      assert_match(/^pci\.0\.7\.0\.tcp=127\.0\.0\.1:6010$/, out)
    end
  end

  def test_graphics_keys_beat_options
    e = entry(disks: [], graphics: true, options: { 'pci.0.7.0.device' => 'evil' })
    out = render("cpus=2\n", e)
    assert_match(/^pci\.0\.7\.0\.device=fbuf$/, out)
    refute_match(/evil/, out)
  end
end
