# frozen_string_literal: true
# test/test_remove_nic_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/remove_nic'

class TestRemoveNicCommand < Minitest::Test
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
          networks:
            - { bridge: storage_vlan60 }
            - { bridge: mgmt_vlan70 }
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_remove_nic_drops_entry
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '1']) }
    nets = VMCtl::Config.load(@inv).vms.fetch('pod34').networks
    assert_equal %w[mgmt_vlan70], nets.map(&:bridge)
  end

  def test_remove_nic_rejects_out_of_range
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '3']) }
    assert_match(/no additional nic/, err.message)
  end

  def test_remove_nic_rejects_zero
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '0']) }
  end

  def test_remove_nic_requires_two_args
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end

  def test_remove_nic_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', '1']) }
    assert_match(/next start/, out)
  end
end
