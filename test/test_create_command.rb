# frozen_string_literal: true
# test/test_create_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/create'
require 'tmpdir'
require 'tempfile'

class TestCreateCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @config_dir = File.join(@dir, 'configs'); FileUtils.mkdir_p(@config_dir)
    File.write(File.join(@config_dir, 'pod.conf'), "cpus=2\n")
    @image_dir = File.join(@dir, 'images'); FileUtils.mkdir_p(@image_dir)
    File.write(File.join(@image_dir, 'base.raw'), 'x' * 1024)
    @vm_root = File.join(@dir, 'vms'); FileUtils.mkdir_p(@vm_root)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        config_dir: #{@config_dir}
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        template: pod.conf
        link_base: 10
        image_dir: #{@image_dir}
        root_size: 1M
        root_from: base.raw
      vms: {}
    YAML
  end

  def load_config
    VMCtl::Config.load(@inv)
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def bridge_ok(extra = {})
    FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => true }.merge(extra))
  end

  def test_create_allocates_provisions_and_registers
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    assert_includes exec.runs, ['zfs', 'create', 'tank/bhyve/pod35']
    assert(exec.runs.any? { |a| a.first == 'cp' && a.any? { |x| x.include?('pod35-root.raw') } })
    reloaded = VMCtl::Config.load(@inv)
    entry = reloaded.vms.fetch('pod35')
    assert_equal 'labs_vlan50', entry.network
    assert_equal 10, entry.link
    assert_equal 'pod35-root.raw', entry.disks.first.file
  end

  def test_create_requires_network
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod35']) }
  end

  def test_create_rejects_duplicate_name
    exec = bridge_ok
    capture_stdout { VMCtl::Commands::Create.new(config: load_config, executor: exec).call(['pod35', '--network', 'labs_vlan50']) }
    err = assert_raises(VMCtl::Commands::CommandError) do
      VMCtl::Commands::Create.new(config: load_config, executor: exec).call(['pod35', '--network', 'labs_vlan50'])
    end
    assert_match(/exists/, err.message)
  end

  def test_create_fails_when_bridge_missing
    exec = FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => false })
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod35', '--network', 'labs_vlan50']) }
  end

  def test_create_extra_disk_flag
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--disk', 'zfs:5M']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    files = entry.disks.map(&:file)
    assert_includes files, 'pod35-root.raw'
    assert_includes files, 'pod35-zfs.raw'
    assert_includes exec.runs, ['truncate', '-s', '5M', File.join(@vm_root, 'pod35', 'pod35-zfs.raw')]
  end

  def test_create_mac_generate
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--mac', 'generate']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, entry.mac)
  end

  def test_create_cloud_init_builds_seed_and_records_template
    File.write(File.join(@config_dir, 'web-base.yml'), "#cloud-config\nhostname: %(name)\n")
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--cloud-init', 'web-base.yml']) }
    assert(exec.runs.any? { |a| a.first == 'makefs' })
    ci = VMCtl::Config.load(@inv).vms.fetch('pod35').cloud_init
    assert_equal 'web-base.yml', ci['user_data']
    refute ci.key?('vars')
  end

  def test_create_cloud_init_with_vars
    File.write(File.join(@config_dir, 'web-base.yml'), "#cloud-config\nrole: %(role)\n")
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--cloud-init', 'web-base.yml', '--var', 'role=web']) }
    ci = VMCtl::Config.load(@inv).vms.fetch('pod35').cloud_init
    assert_equal({ 'role' => 'web' }, ci['vars'])
  end

  def test_create_rejects_missing_cloud_init_template
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    err = assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--cloud-init', 'nope.yml'])
    end
    assert_match(/cloud-init template not found/, err.message)
  end

  def test_dry_run_writes_nothing
    exec = FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => true }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    assert_equal before, File.read(@inv), 'dry-run must not change the inventory file'
  end

  def test_create_rejects_malformed_disk
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    err = assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--disk', 'zfs'])
    end
    assert_match(/--disk/, err.message)
  end

  def test_create_rejects_empty_disk_suffix
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--disk', ':5M'])
    end
  end

  def test_create_rejects_disk_smaller_than_image
    # base.raw is 1024 bytes; requesting 1 byte from it must be rejected.
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    err = assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--disk', 'data:1:from base.raw'])
    end
    assert_match(/smaller/, err.message)
  end

  def test_create_rejects_invalid_root_size
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    err = assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--root-size', 'notasize'])
    end
    assert_match(/invalid size/, err.message)
  end

  def test_create_rejects_invalid_extra_disk_size
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--disk', 'data:bogus'])
    end
  end

  def write_installer_template
    File.write(File.join(@config_dir, 'installer.conf'),
               "cpus=2\npci.0.5.0.port.0.path=%(iso)\n")
  end

  def write_iso
    iso = File.join(@dir, 'install.iso')
    File.write(iso, 'iso')
    iso
  end

  def test_create_iso_records_absolute_path
    write_installer_template
    iso = write_iso
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout do
      cmd.call(['pod36', '--network', 'labs_vlan50',
                '--config', 'installer.conf', '--iso', iso])
    end
    entry = VMCtl::Config.load(@inv).vms.fetch('pod36')
    assert_equal iso, entry.iso
  end

  def test_create_iso_expands_relative_path
    write_installer_template
    write_iso
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    Dir.chdir(@dir) do
      capture_stdout do
        cmd.call(['pod36', '--network', 'labs_vlan50',
                  '--config', 'installer.conf', '--iso', 'install.iso'])
      end
    end
    entry = VMCtl::Config.load(@inv).vms.fetch('pod36')
    assert_equal File.realpath(File.join(@dir, 'install.iso')), File.realpath(entry.iso)
  end

  def test_create_rejects_missing_iso_file
    write_installer_template
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    err = assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod36', '--network', 'labs_vlan50',
                '--config', 'installer.conf', '--iso', '/nonexistent.iso'])
    end
    assert_match(/iso not found/, err.message)
  end

  def test_create_cpus_and_memory
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--cpus', '4', '--memory', '8G']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_equal 4, entry.cpus
    assert_equal '8G', entry.memory
  end

  def test_create_defaults_cpus_memory_when_omitted
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_nil entry.cpus       # nil -> renderer applies defaults.cpus
    assert_nil entry.memory
  end

  def test_create_rejects_bad_cpus
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--cpus', '0'])
    end
  end

  def test_create_rejects_bad_memory
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--memory', '1GB'])
    end
  end

  def test_create_network_none_skips_bridge_and_succeeds
    # If create wrongly probed a 'none' bridge, this false probe would make it
    # raise; success proves the primary-bridge check is skipped for `none`.
    exec = FakeExecutor.new(probes: { 'ngctl info none:' => false })
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod37', '--network', 'none']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod37')
    assert_equal 'none', entry.network
  end
end
