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
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
    )
  end

  def entry(disks:, mac: nil, iso: nil, options: {}, config: 'base.conf')
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: 'labs_vlan50', link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: nil, iso: iso,
      options: options
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
    out = render("cpus=2\nmemory.size=4G\n",
                 entry(disks: [], options: { 'cpus' => 4 }))
    assert_match(/^cpus=4$/, out)
    refute_match(/^cpus=2$/, out)
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
    assert_match(/^cpus=2$/, out)
  end

  def test_output_is_sorted
    out = render("zeta=1\nalpha=2\n", entry(disks: []))
    assert_equal %w[alpha=2 zeta=1], out.split("\n")
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
    assert_match(/^cpus=2$/, out)
  end
end
