# frozen_string_literal: true
# test/test_grow_disk_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/grow_disk'

class TestGrowDiskCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @vm_root = File.join(@dir, 'vms')
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: #{@vm_root}, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: n
          link: 10
          disks:
            - { file: pod34-root.raw, size: 20G }
            - { file: pod34-data.raw, size: 50G }
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_grow_disk_truncates_and_persists
    exec = stopped
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data', '100G']) }
    assert_includes exec.runs, "truncate -s 100G #{File.join(@vm_root, 'pod34', 'pod34-data.raw')}"
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal '100G', entry.disks.find { |d| d.file == 'pod34-data.raw' }.size
  end

  def test_grow_disk_rejects_shrink
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data', '10G']) }
    assert_match(/not larger/, err.message)
  end

  def test_grow_disk_unknown_suffix
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'ghost', '100G']) }
    assert_match(/no disk/, err.message)
  end

  def test_grow_disk_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'data', '100G']) }
    assert_match(/next start/, out)
  end

  def test_grow_disk_requires_three_args
    cmd = VMCtl::Commands::GrowDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data']) }
  end
end
