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

  def test_set_mtu
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--mtu', '1500']) }
    assert_equal 1500, VMCtl::Config.load(@inv).vms.fetch('pod34').mtu
  end

  def test_set_bad_mtu
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--mtu', 'huge']) }
  end

  def test_set_network_none_skips_bridge
    # No ngctl probe should be needed; default probes would answer true anyway,
    # so assert the value was set and no bridge lookup gates it.
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--network', 'none']) }
    assert_equal 'none', VMCtl::Config.load(@inv).vms.fetch('pod34').network
  end

  def test_set_network_none_when_bridge_absent
    # Even if every bridge is missing, --network none must succeed.
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false, 'ngctl info' => false })
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--network', 'none']) }
    assert_equal 'none', VMCtl::Config.load(@inv).vms.fetch('pod34').network
  end

  def test_set_cloud_init_builds_seed_and_records
    File.write(File.join(@dir, 'base.yml'), "#cloud-config\nhostname: %(name)\n")
    exec = stopped
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--cloud-init', 'base.yml']) }
    ci = VMCtl::Config.load(@inv).vms.fetch('pod34').cloud_init
    assert_equal 'base.yml', ci['user_data']
    assert(exec.runs.any? { |a| a.first == 'makefs' })
  end

  def test_set_var_updates_and_rebuilds
    File.write(File.join(@dir, 'base.yml'), "role: %(role)\n")
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--cloud-init', 'base.yml', '--var', 'role=web']) }
    ci = VMCtl::Config.load(@inv).vms.fetch('pod34').cloud_init
    assert_equal({ 'role' => 'web' }, ci['vars'])
  end

  def test_set_no_cloud_init_clears
    File.write(File.join(@dir, 'base.yml'), "x: 1\n")
    VMCtl::Commands::Set.new(config: cfg, executor: stopped).tap do |c|
      capture_stdout { c.call(['pod34', '--cloud-init', 'base.yml']) }
      capture_stdout { c.call(['pod34', '--no-cloud-init']) }
    end
    assert_nil VMCtl::Config.load(@inv).vms.fetch('pod34').cloud_init
  end

  def test_set_cloud_init_rejects_missing_template
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--cloud-init', 'nope.yml']) }
    assert_match(/cloud-init template not found/, err.message)
  end

  def test_set_cpus
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--cpus', '4']) }
    assert_equal 4, VMCtl::Config.load(@inv).vms.fetch('pod34').cpus
  end

  def test_set_memory
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--memory', '2G']) }
    assert_equal '2G', VMCtl::Config.load(@inv).vms.fetch('pod34').memory
  end

  def test_set_rejects_bad_cpus
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--cpus', 'x']) }
  end

  def test_set_rejects_bad_memory
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--memory', '1GB']) }
  end

  def test_set_graphics
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--graphics']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').graphics
  end

  def test_set_no_graphics
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          graphics: true
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-graphics']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').graphics
  end

  def test_set_efi_vars
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--efi-vars']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').efi_vars
  end

  def efi_inventory
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          efi_vars: true
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
  end

  def test_set_no_efi_vars
    efi_inventory
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-efi-vars']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').efi_vars
  end

  def test_set_reset_efi_vars_removes_file
    efi_inventory
    exec = stopped
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--reset-efi-vars']) }
    assert_includes exec.runs, ['rm', '-f', '/bhyve/pod34/pod34-uefi-vars.fd']
  end

  def test_set_reset_efi_vars_errors_when_disabled
    # default inventory (setup) has no efi_vars on pod34
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--reset-efi-vars']) }
    assert_match(/does not have efi_vars/, err.message)
  end
end
