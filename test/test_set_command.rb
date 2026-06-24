# frozen_string_literal: true
# test/test_set_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/set'

class TestSetCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, 'pod.conf'), "cpus=2\n")
    File.write(File.join(@dir, 'inst.conf'), "pci.0.5.0.port.0.path=%(iso)\n")
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          autostart: false
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped(extra = {}) = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false }.merge(extra))
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_set_autostart
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--autostart']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').autostart
  end

  def test_set_no_autostart
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-autostart']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').autostart
  end

  def test_set_network_checks_bridge
    exec = stopped('ngctl info newnet:' => true)
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--network', 'newnet']) }
    assert_equal 'newnet', VMCtl::Config.load(@inv).vms.fetch('pod34').network
  end

  def test_set_network_fails_when_bridge_missing
    exec = stopped('ngctl info newnet:' => false)
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod34', '--network', 'newnet']) }
  end

  def test_set_mac_generate
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--mac', 'generate']) }
    mac = VMCtl::Config.load(@inv).vms.fetch('pod34').mac
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, mac)
  end

  def test_set_config_validates_template
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--config', 'nope.conf']) }
    assert_match(/template not found/, err.message)
  end

  def test_set_iso_requires_pairing
    # pod.conf has no %(iso); setting an iso on it must fail pairing.
    iso = File.join(@dir, 'x.iso'); File.write(iso, 'i')
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--iso', iso]) }
    assert_match(/does not reference/, err.message)
  end

  def test_set_iso_with_installer_template
    iso = File.join(@dir, 'x.iso'); File.write(iso, 'i')
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--config', 'inst.conf', '--iso', iso]) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal iso, entry.iso
    assert_equal 'inst.conf', entry.config
  end

  def test_set_no_iso_clears
    iso = File.join(@dir, 'x.iso'); File.write(iso, 'i')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: inst.conf
          network: labs_vlan50
          link: 10
          iso: #{iso}
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-iso']) }
    assert_nil VMCtl::Config.load(@inv).vms.fetch('pod34').iso
  end

  def test_set_requires_a_field
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end

  def test_set_warns_when_running
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: FakeExecutor.new(probes: { '/dev/vmm/pod34' => true }))
    out = capture_stdout { cmd.call(['pod34', '--autostart']) }
    assert_match(/next start/, out)
  end
end
