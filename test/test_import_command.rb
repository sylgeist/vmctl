# frozen_string_literal: true
# test/test_import_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/import'
require 'tmpdir'

class TestImportCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @vm_root = File.join(@dir, 'vms'); FileUtils.mkdir_p(@vm_root)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        template: pod.conf
        link_base: 10
      vms:
        existing:
          config: pod.conf
          network: labs_vlan50
          link: 10
          disks: []
    YAML
  end

  def make_disks(name, *files_with_bytes)
    d = File.join(@vm_root, name); FileUtils.mkdir_p(d)
    files_with_bytes.each { |f, n| File.write(File.join(d, f), 'x' * n) }
  end

  def load_config; VMCtl::Config.load(@inv); end
  def capture_stdout; out = StringIO.new; $stdout = out; yield; out.string; ensure; $stdout = STDOUT; end

  def test_import_scans_disks_and_allocates_fresh_link
    make_disks('pod40', ['pod40-root.raw', 1024], ['pod40-zfs.raw', 2048])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    capture_stdout { cmd.call(['pod40', '--network', 'labs_vlan50']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod40')
    assert_equal 11, entry.link, 'fresh link allocated (10 is taken)'
    assert_equal 'labs_vlan50', entry.network
    assert_equal %w[pod40-root.raw pod40-zfs.raw], entry.disks.map(&:file).sort
    assert(entry.disks.all? { |d| d.from.nil? })
    assert_equal '1K', entry.disks.find { |d| d.file == 'pod40-root.raw' }.size
  end

  def test_import_requires_network
    make_disks('pod40', ['pod40-root.raw', 1024])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod40']) }
  end

  def test_import_rejects_existing_name
    make_disks('existing', ['existing-root.raw', 1024])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['existing', '--network', 'labs_vlan50']) }
  end

  def test_import_fails_when_dataset_dir_missing
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', '--network', 'labs_vlan50']) }
    assert_match(/not found/, err.message)
  end

  def test_import_fails_when_no_raw_images
    FileUtils.mkdir_p(File.join(@vm_root, 'empty'))
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['empty', '--network', 'labs_vlan50']) }
  end
end
