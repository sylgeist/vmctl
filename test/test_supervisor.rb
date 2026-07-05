# frozen_string_literal: true
# test/test_supervisor.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/supervisor'

class TestSupervisor < Minitest::Test
  def build_vm
    defaults = VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: '/bhyve', zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10,
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
    )
    entry = VMCtl::VMEntry.new(
      name: 'pod34', config: 'pod.conf', network: 'labs_vlan50', link: 10,
      mac: nil, autostart: true, disks: [], cloud_init: nil
    )
    VMCtl::VM.new(entry, defaults)
  end

  def test_reboot_predicate
    assert VMCtl::Supervisor.reboot?(0)
    refute VMCtl::Supervisor.reboot?(1)
    refute VMCtl::Supervisor.reboot?(2)
    refute VMCtl::Supervisor.reboot?(3)
    refute VMCtl::Supervisor.reboot?(4)
  end

  def test_loop_relaunches_on_reboot_then_stops_on_poweroff
    exec = FakeExecutor.new
    statuses = [0, 0, 1]   # reboot, reboot, poweroff
    runs = 0
    runner = -> { statuses[runs].tap { runs += 1 } }
    sup = VMCtl::Supervisor.new(build_vm, executor: exec, runner: runner)
    sup.supervise
    assert_equal 3, runs, "bhyve launched 3 times"
    destroys = exec.runs.select { |a| a.first == 'bhyvectl' && a[1] == '--destroy' }
    assert_equal 3, destroys.length, "destroy runs once per bhyve exit"
  end

  def test_loop_stops_immediately_on_poweroff
    exec = FakeExecutor.new
    runner = -> { 1 }
    sup = VMCtl::Supervisor.new(build_vm, executor: exec, runner: runner)
    sup.supervise
    assert_equal 1, exec.runs.count { |a| a == ['bhyvectl', '--destroy', '--vm=pod34'] }
  end

  def test_loop_stops_when_poweroff_requested_during_run
    exec = FakeExecutor.new
    sup = nil
    calls = 0
    runner = lambda do
      calls += 1
      sup.request_poweroff # simulate a TERM arriving during the run
      0                    # guest reports reboot, but a stop was requested
    end
    sup = VMCtl::Supervisor.new(build_vm, executor: exec, runner: runner)
    sup.supervise
    assert_equal 1, calls, "must not relaunch after poweroff requested"
    assert_equal 1, exec.runs.count { |a| a.first == 'bhyvectl' && a[1] == '--destroy' }
  end
end
