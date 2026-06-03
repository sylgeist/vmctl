# frozen_string_literal: true
# test/test_commands.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/executor'
require 'vmctl/commands/list'
require 'vmctl/commands/status'
require 'vmctl/commands/start'
require 'vmctl/commands/stop'
require 'vmctl/commands/console'
require 'vmctl/commands/restart'
require 'tempfile'

module CmdTestSupport
  INVENTORY = <<~YAML
    defaults:
      config_dir: /bhyve/configs
      vm_root: /bhyve
      zpool: tank/bhyve
      link_base: 10
      run_dir: /tmp/vmctl-test-run
      log_dir: /tmp/vmctl-test-log
    vms:
      pod34:
        config: pod.conf
        network: labs_vlan50
        link: 10
        autostart: true
        disks: [{ file: pod34-root.raw, size: 20G }]
      pod35:
        config: pod.conf
        network: labs_vlan50
        link: 11
        autostart: false
        disks: [{ file: pod35-root.raw, size: 20G }]
  YAML

  def load_config
    f = Tempfile.new(['inv', '.yml'])
    f.write(INVENTORY)
    f.flush
    VMCtl::Config.load(f.path)
  end

  def capture_stdout
    out = StringIO.new
    $stdout = out
    yield
    out.string
  ensure
    $stdout = STDOUT
  end
end

class TestListCommand < Minitest::Test
  include CmdTestSupport

  def test_list_prints_each_vm
    cmd = VMCtl::Commands::List.new(config: load_config, executor: FakeExecutor.new)
    out = capture_stdout { cmd.call([]) }
    assert_match(/pod34/, out)
    assert_match(/pod35/, out)
    assert_match(/labs_vlan50/, out)
    assert_match(/link 10/, out)
  end
end

class TestStatusCommand < Minitest::Test
  include CmdTestSupport

  def test_status_reports_stopped_when_no_vmm_device
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/pod34/, out)
    assert_match(/stopped/, out)
  end

  def test_status_reports_running_when_vmm_device_present
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/running/, out)
  end
end

class TestStartCommand < Minitest::Test
  include CmdTestSupport

  class FakeSupervisor
    attr_reader :started
    def initialize(*); @started = false; end
    def start; @started = true; 4242; end
  end

  def test_start_preflights_bridge_and_starts_supervisor
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => true, '/dev/vmm/pod34' => false }
    )
    started = []
    factory = ->(vm, **) { started << vm.name; FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    assert_equal ['pod34'], started
  end

  def test_start_fails_when_bridge_missing
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => false, '/dev/vmm/pod34' => false }
    )
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod34']) }
  end

  def test_start_refuses_when_already_running
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => true, '/dev/vmm/pod34' => true }
    )
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/already running/, err.message)
  end

  def test_start_all_targets_only_autostart_vms
    exec = FakeExecutor.new(
      probes: {
        'ngctl info labs_vlan50:' => true,
        '/dev/vmm/pod34' => false, '/dev/vmm/pod35' => false
      }
    )
    started = []
    factory = ->(vm, **) { started << vm.name; FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['--all']) }
    assert_equal ['pod34'], started, "only autostart VMs start with --all"
  end

  def test_start_dry_run_prints_command_and_does_not_start
    exec = FakeExecutor.new(dry_run: true)
    started = []
    factory = ->(vm, **) { started << vm.name; FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec,
                                     supervisor_factory: factory)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_empty started, "dry-run must not start a supervisor"
    assert_match(/\[dry-run\]/, out)
    assert_match(%r{bhyve -k /bhyve/configs/pod\.conf}, out)
  end
end

class TestStopCommand < Minitest::Test
  include CmdTestSupport

  def test_stop_no_pidfile_prints_not_running
    exec = FakeExecutor.new
    cmd = VMCtl::Commands::Stop.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/not running/, out)
    assert_empty exec.runs, "no destroy without --force"
  end

  def test_stop_force_no_pidfile_runs_destroy
    exec = FakeExecutor.new
    cmd = VMCtl::Commands::Stop.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['--force', 'pod34']) }
    assert_includes exec.runs, 'bhyvectl --destroy --vm=pod34'
  end

  def test_stop_rejects_unknown_flag
    exec = FakeExecutor.new
    cmd = VMCtl::Commands::Stop.new(config: load_config, executor: exec)
    assert_raises(OptionParser::ParseError) { cmd.call(['--bogus', 'pod34']) }
  end
end

class TestRestartCommand < Minitest::Test
  include CmdTestSupport

  def test_restart_requires_a_name
    cmd = VMCtl::Commands::Restart.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call([]) }
  end

  def test_restart_dry_run_stops_then_prints_start
    # dry-run executor makes both Stop and Start short-circuit (no signals/fork).
    exec = FakeExecutor.new(dry_run: true)
    cmd = VMCtl::Commands::Restart.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/pod34/, out)
    assert_match(%r{bhyve -k /bhyve/configs/pod\.conf}, out, "start invocation printed after stop")
  end
end
