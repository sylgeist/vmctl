# frozen_string_literal: true
# test/test_remove_disk_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/remove_disk'

class TestRemoveDiskCommand < Minitest::Test
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

  def test_remove_disk_drops_entry_keeps_file
    exec = stopped
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'data']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal %w[pod34-root.raw], entry.disks.map(&:file)
    refute(exec.runs.any? { |a| a.first == 'rm' })
    assert_match(/left in place/, out)
  end

  def test_remove_disk_purge_deletes_file
    exec = stopped
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data', '--purge']) }
    assert_includes exec.runs, ['rm', '-f', File.join(@vm_root, 'pod34', 'pod34-data.raw')]
  end

  def test_remove_disk_refuses_root
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'root']) }
    assert_match(/root/, err.message)
  end

  def test_remove_disk_purge_refused_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data', '--purge']) }
    assert_match(/running/, err.message)
  end

  def test_remove_disk_unknown_suffix
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'ghost']) }
  end

  def test_remove_disk_requires_two_args
    cmd = VMCtl::Commands::RemoveDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end
end
