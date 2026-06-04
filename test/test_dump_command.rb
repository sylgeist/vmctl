# frozen_string_literal: true
# test/test_dump_command.rb
require 'test_helper'
require 'stringio'
require 'vmctl/config'
require 'vmctl/commands/dump'
require 'tempfile'

class TestDumpCommand < Minitest::Test
  INVENTORY = <<~YAML
    defaults:
      config_dir: /bhyve/configs
      vm_root: /bhyve
      zpool: tank/bhyve
      template: pod.conf
      link_base: 10
    vms:
      pod34:
        config: pod.conf
        network: labs_vlan50
        link: 10
        disks: []
  YAML

  def load_config
    f = Tempfile.new(['inv', '.yml'])
    f.write(INVENTORY)
    f.flush
    VMCtl::Config.load(f.path)
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_dump_captures_and_prints_resolved_config
    exec = FakeExecutor.new(captures: { 'config.dump=1' => "config.dump=1\ncpus=2\nmemory.size=4G\n" })
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: exec)
    out = capture_stdout { cmd.call(['pod34']) }
    # The command passed to capture must include config.dump and the VM name.
    assert(exec.captures.any? { |c| c.include?('-o config.dump=1') && c.include?('pod34') })
    assert_match(/memory\.size=4G/, out)
  end

  def test_dump_requires_a_name
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call([]) }
  end

  def test_dump_unknown_vm
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost']) }
  end
end
