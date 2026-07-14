# frozen_string_literal: true
# test/test_info_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/info'

class TestInfoCommand < Minitest::Test
  # Builds an inventory with one or two VMs and a flavor template on disk.
  # Returns [config, run_dir] — run_dir is a real tmpdir so pidfiles can be
  # written to exercise the running/stale header branches.
  def load_config(second: false)
    dir = Dir.mktmpdir
    run_dir = Dir.mktmpdir
    File.write(File.join(dir, 'pod.conf'),
               "cpus=1\nmemory.size=1G\nlpc.com1.path=/dev/nmdm%(link)A\n")
    vms = +<<~YAML
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          cpus: 2
          memory: 4G
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    if second
      vms << <<YAML
  pod35:
    config: pod.conf
    network: labs_vlan50
    link: 11
    cpus: 1
    memory: 2G
    disks: [{ file: pod35-root.raw, size: 20G }]
YAML
    end
    inv = <<~YAML + vms
      defaults:
        config_dir: #{dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: #{run_dir}
    YAML
    f = Tempfile.new(['inv', '.yml'])
    f.write(inv)
    f.flush
    [VMCtl::Config.load(f.path), run_dir]
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def cmd(config, exec)
    VMCtl::Commands::Info.new(config: config, executor: exec)
  end

  def test_info_stopped_vm_shows_allocation
    config, = load_config
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^pod34: stopped$/, out)
    assert_match(/^  cpus\s+2$/, out)
    assert_match(/^  memory\s+4G$/, out)
    assert_match(%r{^  disks\s+root\s+20G\s+/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(/^  network\s+labs_vlan50\s+link 10$/, out)
  end

  def test_info_unknown_vm_raises
    config, = load_config
    exec = FakeExecutor.new
    assert_raises(VMCtl::Commands::CommandError) { cmd(config, exec).call(['ghost']) }
  end

  def test_info_running_vm_shows_pid
    config, run_dir = load_config
    File.write(File.join(run_dir, 'pod34.pid'), "4821")
    exec = FakeExecutor.new(probes: { 'test -e' => true, 'kill -0' => true })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^pod34: running \(pid 4821\)$/, out)
  end

  def test_info_stale_vm
    config, = load_config
    # vmm device present but no live supervisor (kill -0 fails).
    exec = FakeExecutor.new(probes: { 'test -e' => true, 'kill -0' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^pod34: stale$/, out)
  end

  def test_info_wired_memory
    config, = load_config
    config.vms['pod34'].memory_wired = true
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(/^  memory\s+4G\s+\(wired\)$/, out)
  end

  def test_info_multi_disk_and_nic
    config, = load_config
    e = config.vms['pod34']
    e.disks << VMCtl::Disk.new(file: 'pod34-data.raw', size: '100G', from: nil)
    e.networks = [VMCtl::Nic.new(bridge: 'mgmt0', mtu: nil, mac: nil)]
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['pod34']) }
    assert_match(%r{^  disks\s+root\s+20G\s+/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(%r{^\s+data\s+100G\s+/bhyve/pod34/pod34-data\.raw$}, out)
    assert_match(/^  network\s+labs_vlan50\s+link 10$/, out)
    assert_match(/^\s+mgmt0$/, out)
  end

  def test_info_all_prints_a_block_per_vm
    config, = load_config(second: true)
    exec = FakeExecutor.new(probes: { 'test -e' => false })
    out = capture_stdout { cmd(config, exec).call(['--all']) }
    assert_match(/^pod34: stopped$/, out)
    assert_match(/^pod35: stopped$/, out)
    # blocks are separated by a blank line
    assert_match(/\n\npod35:/, out)
  end
end
