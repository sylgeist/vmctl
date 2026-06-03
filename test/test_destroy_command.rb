# frozen_string_literal: true
# test/test_destroy_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/destroy'
require 'tmpdir'

class TestDestroyCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults:
        vm_root: #{@dir}
        zpool: tank/bhyve
        link_base: 10
      vms:
        pod35:
          config: pod.conf
          network: labs_vlan50
          link: 10
          disks: [{ file: pod35-root.raw, size: 20G }]
    YAML
  end

  def load_config; VMCtl::Config.load(@inv); end
  def capture_stdout; out = StringIO.new; $stdout = out; yield; out.string; ensure; $stdout = STDOUT; end

  def stopped_exec(extra = {})
    FakeExecutor.new(probes: { '/dev/vmm/pod35' => false }.merge(extra))
  end

  def test_destroy_removes_from_inventory
    exec = stopped_exec
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--yes']) }
    refute VMCtl::Config.load(@inv).vms.key?('pod35')
    refute(exec.runs.any? { |c| c.start_with?('zfs destroy') }, 'no purge without --purge')
  end

  def test_destroy_purge_runs_zfs_destroy
    exec = stopped_exec
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--purge', '--yes']) }
    assert_includes exec.runs, 'zfs destroy tank/bhyve/pod35'
  end

  def test_destroy_refuses_running_vm
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod35' => true })
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod35', '--yes']) }
    assert_match(/running/, err.message)
  end

  def test_destroy_unknown_vm
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: stopped_exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost', '--yes']) }
  end

  def test_dry_run_writes_nothing
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod35' => false }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--purge', '--yes']) }
    assert_equal before, File.read(@inv), 'dry-run must not change the inventory file'
  end

  def test_destroy_aborts_when_confirmation_declined
    cmd = VMCtl::Commands::Destroy.new(config: load_config, executor: stopped_exec)
    old_stdin = $stdin
    $stdin = StringIO.new("no\n")
    begin
      assert_raises(VMCtl::Commands::CommandError) do
        capture_stdout { cmd.call(['pod35']) } # no --yes → prompts
      end
    ensure
      $stdin = old_stdin
    end
    assert VMCtl::Config.load(@inv).vms.key?('pod35'), 'declined destroy must leave the VM'
  end
end
