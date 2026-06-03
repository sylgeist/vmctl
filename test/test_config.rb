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

  def test_raises_on_non_hash_top_level
    f = write_inventory("- just\n- a\n- list\n")
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_raises_on_non_mapping_vms
    f = write_inventory("vms:\n  - a\n  - b\n")
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_raises_on_non_mapping_vm_body
    f = write_inventory("vms:\n  pod1: just-a-string\n")
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_raises_on_non_integer_link_base
    f = write_inventory("defaults:\n  link_base: not-a-number\nvms: {}\n")
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_raises_on_non_mapping_disk_entry
    f = write_inventory("vms:\n  pod1:\n    network: n\n    link: 10\n    disks:\n      - just-a-string\n")
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_new_provisioning_defaults_fill_in
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/bhyve/images', cfg.defaults.image_dir
    assert_equal '20G', cfg.defaults.root_size
    assert_nil cfg.defaults.root_from
    f.close
  end

  def test_new_defaults_are_overridable_and_round_trip
    yaml = "defaults:\n  image_dir: /tank/img\n  root_size: 40G\n  root_from: base.raw\nvms: {}\n"
    f = write_inventory(yaml)
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/tank/img', cfg.defaults.image_dir
    assert_equal '40G', cfg.defaults.root_size
    assert_equal 'base.raw', cfg.defaults.root_from
    out = File.join(Dir.mktmpdir, 'out.yml')
    cfg.save(out)
    reloaded = VMCtl::Config.load(out)
    assert_equal '/tank/img', reloaded.defaults.image_dir
    assert_equal '40G', reloaded.defaults.root_size
    assert_equal 'base.raw', reloaded.defaults.root_from
    f.close
  end

  def test_add_and_remove_vm
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    entry = VMCtl::VMEntry.new(
      name: 'pod99', config: 'pod.conf', network: 'labs_vlan50', link: 10,
      mac: nil, autostart: false,
      disks: [VMCtl::Disk.new(file: 'pod99-root.raw', size: '20G', from: nil)],
      cloud_init: nil
    )
    cfg.add_vm(entry)
    assert cfg.vms.key?('pod99')
    cfg.remove_vm('pod99')
    refute cfg.vms.key?('pod99')
    f.close
  end
end
