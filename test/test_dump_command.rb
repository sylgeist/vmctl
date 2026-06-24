# frozen_string_literal: true
# test/test_dump_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'vmctl/config'
require 'vmctl/commands/dump'
require 'tempfile'

class TestDumpCommand < Minitest::Test
  def load_config(template: "cpus=2\nmemory.size=4G\nlpc.com1.path=/dev/nmdm%(link)A\n",
                  config: 'pod.conf')
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'pod.conf'), template)
    inv = <<~YAML
      defaults:
        config_dir: #{dir}
        vm_root: /bhyve
        zpool: tank/bhyve
        link_base: 10
        run_dir: /var/run/vmctl
      vms:
        pod34:
          config: #{config}
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    f = Tempfile.new(['inv', '.yml'])
    f.write(inv)
    f.flush
    VMCtl::Config.load(f.path)
  end

  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_dump_prints_rendered_config
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    out = capture_stdout { cmd.call(['pod34']) }
    assert_match(/^memory\.size=4G$/, out)
    assert_match(%r{^pci\.0\.3\.0\.path=/bhyve/pod34/pod34-root\.raw$}, out)
    assert_match(%r{^lpc\.com1\.path=/dev/nmdm10A$}, out)
  end

  def test_dump_requires_a_name
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call([]) }
  end

  def test_dump_unknown_vm
    cmd = VMCtl::Commands::Dump.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['ghost']) }
  end

  def test_dump_missing_flavor_file_raises
    cmd = VMCtl::Commands::Dump.new(config: load_config(config: 'nope.conf'),
                                    executor: FakeExecutor.new)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
    assert_match(/could not render config/, err.message)
  end
end
