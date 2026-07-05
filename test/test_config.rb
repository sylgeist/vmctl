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

  def test_iso_round_trips
    f = write_inventory(VALID_INVENTORY + "    iso: /bhyve/isos/freebsd-14.3.iso\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal '/bhyve/isos/freebsd-14.3.iso', cfg.vms['pod34'].iso
    out = File.join(Dir.mktmpdir, 'out.yml')
    cfg.save(out)
    assert_equal '/bhyve/isos/freebsd-14.3.iso', VMCtl::Config.load(out).vms['pod34'].iso
    f.close
  end

  def test_iso_omitted_from_yaml_when_nil
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    assert_nil cfg.vms['pod34'].iso
    refute_match(/^\s*iso:/, cfg.to_yaml)
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

  def test_options_default_empty
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    assert_equal({}, cfg.vms.fetch('pod34').options)
    f.close
  end

  def test_options_parsed_and_roundtrip
    inv = <<~YAML
      defaults: { config_dir: /c, vm_root: /v, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: []
          options:
            cpus: 4
            memory.size: 8G
    YAML
    f = write_inventory(inv)
    cfg = VMCtl::Config.load(f.path)
    assert_equal({ 'cpus' => 4, 'memory.size' => '8G' }, cfg.vms.fetch('pod34').options)

    out = Tempfile.new(['out', '.yml'])
    cfg.save(out.path)
    reloaded = VMCtl::Config.load(out.path)
    assert_equal({ 'cpus' => 4, 'memory.size' => '8G' }, reloaded.vms.fetch('pod34').options)
    f.close; out.close
  end

  def test_options_absent_not_emitted
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    out = Tempfile.new(['out', '.yml'])
    cfg.save(out.path)
    refute_match(/options:/, File.read(out.path))
    f.close; out.close
  end

  def test_options_must_be_mapping
    inv = "vms:\n  pod34:\n    network: n\n    link: 10\n    disks: []\n    options: [1,2]\n"
    f = write_inventory(inv)
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_disk_parse_basic
    d = VMCtl::Disk.parse('pod34', 'data:50G')
    assert_equal 'pod34-data.raw', d.file
    assert_equal '50G', d.size
    assert_nil d.from
  end

  def test_disk_parse_with_from
    d = VMCtl::Disk.parse('pod34', 'data:50G:from gold.raw')
    assert_equal 'pod34-data.raw', d.file
    assert_equal '50G', d.size
    assert_equal 'gold.raw', d.from
  end

  def test_disk_parse_rejects_missing_size
    assert_raises(ArgumentError) { VMCtl::Disk.parse('pod34', 'data') }
  end

  def test_disk_parse_rejects_empty_suffix
    assert_raises(ArgumentError) { VMCtl::Disk.parse('pod34', ':50G') }
  end

  def test_networks_default_empty_and_mtu_nil
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    vm = cfg.vms.fetch('pod34')
    assert_equal [], vm.networks
    assert_nil vm.mtu
    f.close
  end

  def test_networks_and_mtu_parse_and_roundtrip
    inv = <<~YAML
      defaults: { config_dir: /c, vm_root: /v, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          mtu: 1500
          disks: []
          networks:
            - { bridge: storage_vlan60, mtu: 9000, mac: 5a:9c:fc:00:00:20 }
            - { bridge: mgmt_vlan70 }
    YAML
    f = write_inventory(inv)
    cfg = VMCtl::Config.load(f.path)
    vm = cfg.vms.fetch('pod34')
    assert_equal 1500, vm.mtu
    assert_equal 2, vm.networks.length
    assert_equal 'storage_vlan60', vm.networks[0].bridge
    assert_equal 9000, vm.networks[0].mtu
    assert_equal '5a:9c:fc:00:00:20', vm.networks[0].mac
    assert_equal 'mgmt_vlan70', vm.networks[1].bridge
    assert_nil vm.networks[1].mtu
    assert_nil vm.networks[1].mac

    out = Tempfile.new(['out', '.yml'])
    cfg.save(out.path)
    r = VMCtl::Config.load(out.path).vms.fetch('pod34')
    assert_equal 1500, r.mtu
    assert_equal %w[storage_vlan60 mgmt_vlan70], r.networks.map(&:bridge)
    assert_equal 9000, r.networks[0].mtu
    assert_nil r.networks[1].mtu
    f.close; out.close
  end

  def test_networks_and_mtu_absent_not_emitted
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    out = Tempfile.new(['out', '.yml'])
    cfg.save(out.path)
    body = File.read(out.path)
    refute_match(/networks:/, body)
    refute_match(/mtu:/, body)
    f.close; out.close
  end

  def test_networks_must_be_list_of_mappings_with_bridge
    bad_type = "vms:\n  p:\n    network: n\n    link: 10\n    disks: []\n    networks: 5\n"
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(write_inventory(bad_type).path) }
    no_bridge = "vms:\n  p:\n    network: n\n    link: 10\n    disks: []\n    networks: [{ mtu: 9000 }]\n"
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(write_inventory(no_bridge).path) }
  end
end
