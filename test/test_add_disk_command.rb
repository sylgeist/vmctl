# frozen_string_literal: true
# test/test_add_disk_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/add_disk'

class TestAddDiskCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @vm_root = File.join(@dir, 'vms')
    @image_dir = File.join(@dir, 'images'); FileUtils.mkdir_p(@image_dir)
    File.write(File.join(@image_dir, 'gold.raw'), 'x' * 1024)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        config_dir: #{@dir}
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        link_base: 10
        image_dir: #{@image_dir}
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_add_disk_creates_file_and_persists
    exec = stopped
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data:50G']) }
    assert_includes exec.runs, ['truncate', '-s', '50G', File.join(@vm_root, 'pod34', 'pod34-data.raw')]
    entry = VMCtl::Config.load(@inv).vms.fetch('pod34')
    assert_equal %w[pod34-root.raw pod34-data.raw], entry.disks.map(&:file)
  end

  def test_add_disk_from_image
    exec = stopped
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data:50G:from gold.raw']) }
    assert(exec.runs.any? { |a| a.first == 'cp' && a.any? { |x| x.include?('gold.raw') } })
  end

  def test_add_disk_rejects_duplicate_suffix
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'root:20G']) }
    assert_match(/already has disk/, err.message)
  end

  def test_add_disk_rejects_ninth_disk
    eight = (0...8).map { |i| "{ file: pod34-d#{i}.raw, size: 1G }" }.join(', ')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: #{@vm_root}, zpool: tank, link_base: 10, image_dir: #{@image_dir} }
      vms:
        pod34:
          network: n
          link: 10
          disks: [#{eight}]
    YAML
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data:1G']) }
    assert_match(/8 disks/, err.message)
  end

  def test_add_disk_rejects_bad_size
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'data:bogus']) }
  end

  def test_add_disk_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'data:50G']) }
    assert_match(/next start/, out)
  end

  def test_add_disk_dry_run_does_not_persist
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'data:50G']) }
    assert_equal before, File.read(@inv)
  end

  def test_add_disk_unknown_vm
    cmd = VMCtl::Commands::AddDisk.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', 'data:50G']) }
  end
end
