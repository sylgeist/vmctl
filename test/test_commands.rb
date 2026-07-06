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
require 'tmpdir'

module CmdTestSupport
  def config_dir
    @config_dir ||= begin
      d = Dir.mktmpdir
      File.write(File.join(d, 'pod.conf'),
                 "cpus=2\nlpc.com1.path=/dev/nmdm%(link)A\n")
      d
    end
  end

  def run_dir
    @run_dir ||= Dir.mktmpdir
  end

  def inventory
    <<~YAML
      defaults:
        config_dir: #{config_dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
        log_dir: #{run_dir}
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
  end

  def load_config
    f = Tempfile.new(['inv', '.yml'])
    f.write(inventory)
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

  def test_status_reports_running_when_vmm_and_live_supervisor
    File.write(File.join(run_dir, 'pod34.pid'), '4242')
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'kill -0 4242' => true })
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/running/, out)
    assert_match(/pid 4242/, out)
  end

  def test_status_reports_stale_when_vmm_but_no_live_supervisor
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })  # no pidfile -> stale
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/stale/, out)
    assert_match(/stop --force pod34/, out)
    refute_match(/running/, out)
  end

  def graphics_config
    inv = <<~YAML
      defaults:
        config_dir: #{config_dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
        log_dir: #{run_dir}
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          graphics: true
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    f = Tempfile.new(['inv', '.yml']); f.write(inv); f.flush
    VMCtl::Config.load(f.path)
  end

  def test_status_shows_vnc_endpoint_for_graphics_vm
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
    cmd = VMCtl::Commands::Status.new(config: graphics_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/vnc 0\.0\.0\.0:5910/, out)
  end

  def test_status_omits_vnc_for_non_graphics_vm
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
    cmd = VMCtl::Commands::Status.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    refute_match(/vnc/, out)
  end

  def test_status_shows_vnc_endpoint_when_running
    File.write(File.join(run_dir, 'pod34.pid'), '4242')
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'kill -0 4242' => true })
    cmd = VMCtl::Commands::Status.new(config: graphics_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/running/, out)
    assert_match(/vnc 0\.0\.0\.0:5910/, out)
  end

  def test_status_shows_vnc_endpoint_when_stale
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })  # no pidfile -> stale
    cmd = VMCtl::Commands::Status.new(config: graphics_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/stale/, out)
    assert_match(/vnc 0\.0\.0\.0:5910/, out)
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
    File.write(File.join(run_dir, 'pod34.pid'), '4242')
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'kill -0 4242' => true })
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/already running/, err.message)
  end

  def test_start_reports_stale_vmm_device
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })  # no pidfile -> stale
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/stale vmm device/, err.message)
    assert_match(/stop --force pod34/, err.message)
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
    assert_match(%r{bhyve -k .*/pod34\.conf pod34}, out)
  end

  def test_start_writes_ephemeral_config
    exec = FakeExecutor.new(
      probes: { 'ngctl info labs_vlan50:' => true, '/dev/vmm/pod34' => false }
    )
    factory = ->(_vm, **) { FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: load_config, executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    written = File.read(File.join(run_dir, 'pod34.conf'))
    assert_match(/^cpus=1$/, written)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, written)
  end

  def config_with_networks(networks_yaml)
    inv = <<~YAML
      defaults:
        config_dir: #{config_dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
        log_dir: #{run_dir}
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
          networks:
      #{networks_yaml}
    YAML
    f = Tempfile.new(['inv', '.yml']); f.write(inv); f.flush
    VMCtl::Config.load(f.path)
  end

  def test_start_validates_every_nic_bridge
    cfg = config_with_networks("        - { bridge: storage_vlan60 }\n")
    exec = FakeExecutor.new(probes: {
      '/dev/vmm/pod34' => false,
      'ngctl info labs_vlan50:' => true,
      'ngctl info storage_vlan60:' => false  # second bridge missing
    })
    cmd = VMCtl::Commands::Start.new(config: cfg, executor: exec,
                                     supervisor_factory: ->(_vm, **) { flunk 'must not start' })
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod34']) }
  end

  def test_start_rejects_more_than_eight_nics
    nets = (1..8).map { |i| "        - { bridge: b#{i} }" }.join("\n") + "\n"
    cfg = config_with_networks(nets)   # 1 primary + 8 = 9
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
    cmd = VMCtl::Commands::Start.new(config: cfg, executor: exec,
                                     supervisor_factory: ->(_vm, **) { flunk 'must not start' })
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/max 8/, err.message)
  end

  # A config whose VM's template declares a bootrom path.
  def bootrom_config(rom)
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'uefi.conf'),
               "bootrom=#{rom}\nlpc.com1.path=/dev/nmdm%(link)A\n")
    inv = <<~YAML
      defaults:
        config_dir: #{dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
        log_dir: #{run_dir}
      vms:
        pod34:
          config: uefi.conf
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    f = Tempfile.new(['inv', '.yml']); f.write(inv); f.flush
    VMCtl::Config.load(f.path)
  end

  def test_start_refuses_when_bootrom_missing
    rom = '/fw/BHYVE_UEFI.fd'
    exec = FakeExecutor.new(probes: {
      'ngctl info labs_vlan50:' => true,
      '/dev/vmm/pod34' => false,
      "test -e #{rom}" => false          # bootrom file absent
    })
    cmd = VMCtl::Commands::Start.new(config: bootrom_config(rom), executor: exec,
                                     supervisor_factory: ->(_vm, **) { flunk 'must not start' })
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/bootrom not found/, err.message)
    assert_match(%r{/fw/BHYVE_UEFI\.fd}, err.message)
  end

  def test_start_allows_when_bootrom_present
    rom = '/fw/BHYVE_UEFI.fd'
    # bootrom probe unspecified -> FakeExecutor returns true -> check passes.
    exec = FakeExecutor.new(probes: {
      'ngctl info labs_vlan50:' => true,
      '/dev/vmm/pod34' => false
    })
    started = []
    factory = ->(vm, **) { started << vm.name; TestStartCommand::FakeSupervisor.new }
    cmd = VMCtl::Commands::Start.new(config: bootrom_config(rom), executor: exec,
                                     supervisor_factory: factory)
    capture_stdout { cmd.call(['pod34']) }
    assert_equal ['pod34'], started
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
    assert_includes exec.runs, ['bhyvectl', '--destroy', '--vm=pod34']
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
    assert_match(%r{bhyve -k .*/pod34\.conf pod34}, out, "start invocation printed after stop")
  end
end
