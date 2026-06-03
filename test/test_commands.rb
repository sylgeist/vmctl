# frozen_string_literal: true
# test/test_commands.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/executor'
require 'vmctl/commands/list'
require 'vmctl/commands/status'
require 'vmctl/commands/start'
require 'vmctl/commands/console'
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
end
