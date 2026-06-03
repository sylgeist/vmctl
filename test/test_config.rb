# frozen_string_literal: true
# test/test_config.rb
require 'test_helper'
require 'vmctl/config'
require 'tempfile'
require 'tmpdir'

VALID_INVENTORY = <<~YAML
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
      mac: null
      autostart: true
      disks:
        - { file: pod34-root.raw, size: 20G, from: base-14.raw }
        - { file: pod34-zfs.raw, size: 100G }
YAML

class TestConfig < Minitest::Test
  def write_inventory(content)
    f = Tempfile.new(['inventory', '.yml'])
    f.write(content)
    f.flush
    f
  end

  def test_loads_defaults
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/bhyve/configs', cfg.defaults.config_dir
    assert_equal 'tank/bhyve', cfg.defaults.zpool
    assert_equal 10, cfg.defaults.link_base
    f.close
  end

  def test_defaults_fill_in_missing_keys
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal 10, cfg.defaults.link_base
    assert_equal '/var/run/vmctl', cfg.defaults.run_dir
    assert_equal '/var/log/vmctl', cfg.defaults.log_dir
    f.close
  end

  def test_loads_vm_entry
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    vm = cfg.vms.fetch('pod34')
    assert_equal 'labs_vlan50', vm.network
    assert_equal 10, vm.link
    assert_nil vm.mac
    assert_equal true, vm.autostart
    assert_equal 2, vm.disks.length
    assert_equal 'pod34-root.raw', vm.disks.first.file
    assert_equal 'base-14.raw', vm.disks.first.from
    assert_nil vm.disks.last.from
    f.close
  end

  def test_raises_on_missing_file
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load('/nonexistent.yml') }
  end

  def test_save_round_trips
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    out = File.join(Dir.mktmpdir, 'out.yml')
    cfg.save(out)
    reloaded = VMCtl::Config.load(out)
    assert_equal cfg.vms.keys, reloaded.vms.keys
    assert_equal 10, reloaded.vms['pod34'].link
    assert_equal '20G', reloaded.vms['pod34'].disks.first.size
    f.close
  end

  def test_save_is_atomic_no_partial_file_on_same_dir
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    dir = Dir.mktmpdir
    out = File.join(dir, 'inv.yml')
    cfg.save(out)
    leftovers = Dir.children(dir).reject { |n| n == 'inv.yml' }
    assert_empty leftovers, "atomic save must not leave temp files: #{leftovers}"
    f.close
  end
end
