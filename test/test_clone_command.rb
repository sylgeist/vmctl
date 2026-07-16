# frozen_string_literal: true
# test/test_clone_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/clone'
require 'tmpdir'

class TestCloneCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @config_dir = File.join(@dir, 'configs'); FileUtils.mkdir_p(@config_dir)
    File.write(File.join(@config_dir, 'pod.conf'), "cpus=2\n")
    @vm_root = File.join(@dir, 'vms'); FileUtils.mkdir_p(@vm_root)
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        config_dir: #{@config_dir}
        vm_root: #{@vm_root}
        zpool: tank/bhyve
        template: pod.conf
        link_base: 10
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          mac: 5a:9c:fc:11:22:33
          autostart: true
          cpus: 4
          memory: 8G
          graphics: true
          efi_vars: true
          disks:
            - { file: pod34-root.raw, size: 20G }
            - { file: pod34-data.raw, size: 50G }
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

  # Source stopped (no vmm device) + inherited bridge present.
  def ready_exec(extra = {})
    FakeExecutor.new(probes: { '/dev/vmm/pod34' => false,
                               'ngctl info labs_vlan50:' => true }.merge(extra))
  end

  def test_clone_copies_dataset_and_registers_with_fresh_identity
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'web1']) }

    assert_includes exec.runs, ['zfs', 'snapshot', 'tank/bhyve/pod34@vmctl-clone-web1']
    assert_includes exec.pipes,
                    [['zfs', 'send', 'tank/bhyve/pod34@vmctl-clone-web1'],
                     ['zfs', 'recv', 'tank/bhyve/web1']]
    assert_match(/cloned pod34 -> web1 \(link 11\)/, out)

    e = VMCtl::Config.load(@inv).vms.fetch('web1')
    assert_equal 11, e.link                 # fresh: next free after pod34's 10
    refute_equal 'pod34', e.name
    refute_equal '5a:9c:fc:11:22:33', e.mac # fresh MAC, not the source's
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, e.mac)
    assert_equal false, e.autostart         # reset off
  end

  def test_clone_inherits_config_fields
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1']) }
    e = VMCtl::Config.load(@inv).vms.fetch('web1')
    assert_equal 'labs_vlan50', e.network
    assert_equal 'pod.conf', e.config
    assert_equal 4, e.cpus
    assert_equal '8G', e.memory
    assert_equal true, e.graphics
    assert_equal true, e.efi_vars
  end

  def test_clone_renames_disk_files_to_new_prefix
    exec = ready_exec
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod34', 'web1']) }
    files = VMCtl::Config.load(@inv).vms.fetch('web1').disks.map(&:file)
    assert_equal ['web1-root.raw', 'web1-data.raw'], files
    assert_includes exec.runs, ['mv', File.join(@vm_root, 'web1', 'pod34-root.raw'),
                                File.join(@vm_root, 'web1', 'web1-root.raw')]
  end

  def test_clone_rejects_unknown_source
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: ready_exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', 'web1']) }
  end

  def test_clone_rejects_duplicate_new_name
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: ready_exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'pod34']) }
    assert_match(/exists/, err.message)
  end

  def test_clone_requires_source_and_name
    cmd = VMCtl::Commands::Clone.new(config: load_config, executor: ready_exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end
end
