# frozen_string_literal: true
# test/test_add_nic_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/add_nic'

class TestAddNicCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
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

  def test_add_nic_appends_and_persists
    exec = stopped('ngctl info storage_vlan60:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'storage_vlan60']) }
    nets = VMCtl::Config.load(@inv).vms.fetch('pod34').networks
    assert_equal 1, nets.length
    assert_equal 'storage_vlan60', nets[0].bridge
    assert_nil nets[0].mtu
    assert_nil nets[0].mac
  end

  def test_add_nic_mtu_and_literal_mac
    exec = stopped('ngctl info b:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'b', '--mtu', '1500', '--mac', '5a:9c:fc:00:00:21']) }
    nic = VMCtl::Config.load(@inv).vms.fetch('pod34').networks[0]
    assert_equal 1500, nic.mtu
    assert_equal '5a:9c:fc:00:00:21', nic.mac
  end

  def test_add_nic_mac_generate_stores_concrete
    exec = stopped('ngctl info b:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'b', '--mac', 'generate']) }
    nic = VMCtl::Config.load(@inv).vms.fetch('pod34').networks[0]
    assert_match(/\A5a:9c:fc(:[0-9a-f]{2}){3}\z/, nic.mac)
  end

  def test_add_nic_rejects_missing_bridge
    exec = stopped('ngctl info nope:' => false)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod34', 'nope']) }
  end

  def test_add_nic_rejects_ninth_nic
    nets = (1..7).map { |i| "        - { bridge: b#{i} }" }.join("\n") + "\n"
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
          networks:
    #{nets}
    YAML
    exec = stopped('ngctl info b8:' => true)   # 1 primary + 7 = 8, adding -> 9
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'b8']) }
    assert_match(/max 8/, err.message)
  end

  def test_add_nic_bad_mtu
    exec = stopped('ngctl info b:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'b', '--mtu', 'huge']) }
  end

  def test_add_nic_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'ngctl info b:' => true })
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'b']) }
    assert_match(/next start/, out)
  end

  def test_add_nic_dry_run_does_not_persist
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false, 'ngctl info b:' => true }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'b']) }
    assert_equal before, File.read(@inv)
  end
end
