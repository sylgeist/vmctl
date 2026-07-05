# Multi-NIC + Generated Networking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate all `pci.0.4.N` network devices from the inventory (primary scalars + a new `networks:` list), with per-NIC MTU (default 9000) and MAC (incl. `generate`), a `network: none` sentinel for disconnected VMs, and `add-nic`/`remove-nic`/`set --mtu`/`set --network none` commands.

**Architecture:** Networking joins disks as an inventory-driven, generated part of the ephemeral bhyve config. A new `net_keys` generator is appended to `ConfigRenderer::GENERATORS` (the seam left in PR #6); the primary NIC stays the `network`/`link`/`mac` scalars (nic 0), `networks:` adds nics 1+, and the `pci.0.4.*` block is removed from templates. PCI function numbers are assigned sequentially over present NICs (no function-0 gap); peerhook/socket names are role-based (`link<link>` / `link<link>_<j+1>`).

**Tech Stack:** Ruby (stdlib only), minitest, `FakeExecutor` test double.

## Global Constraints

- Ruby 4.0 (CI: `ruby -Ilib -Itest test/run_all.rb`). No new gem dependencies.
- Every source file starts with `# frozen_string_literal: true` then `# lib/vmctl/<path>`.
- Tests are minitest named `test/test_*.rb`, using `FakeExecutor`. Single file: `ruby -Ilib -Itest test/test_x.rb`. Single test: `... -n test_name`. Full suite: `ruby -Ilib -Itest test/run_all.rb`.
- User-facing errors are `VMCtl::Commands::CommandError` (CLI → exit 1); load-time schema errors are `VMCtl::ConfigError`.
- NICs live at `pci.0.4.N`, N = sequential function over **present** NICs, **max 8 total** (primary present ? 1 : 0) + `networks.length`.
- peerhook/socket are **role-based**: primary → `link<link>` / `bhyve_<name>`; the *j*-th `networks:` entry (0-based) → `link<link>_<j+1>` / `bhyve_<name>_<j+1>`.
- `device`=`virtio-net`, `backend`=`netgraph` are fixed. `mtu` defaults to **9000**. `mac` is emitted only when present.
- `network: none` → no primary NIC, no bridge validation for it; the VM still has its `link` (console).
- MAC `generate` is resolved to a concrete address at add-time (stored literally); the renderer never resolves `generate`.
- Values stored as authored (nil when absent); the renderer applies the 9000 default. `vm_to_h` stays byte-stable for existing inventories.
- Git commits end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Work on branch `feat/multi-nic`.

---

## Task 1: `Nic` struct + `mtu`/`networks` on `VMEntry`

**Files:**
- Modify: `lib/vmctl/config.rb`
- Test: `test/test_config.rb`

**Interfaces:**
- Produces: `Nic = Struct.new(:bridge, :mtu, :mac, keyword_init: true)`. `VMEntry#mtu` (Integer or nil) and `VMEntry#networks` (Array<Nic>, `[]` when loaded and absent). `vm_to_h` emits `'mtu'` only when non-nil and `'networks'` only when a non-empty array; each emitted nic drops nil `mtu`/`mac`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config.rb`:

```ruby
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb -n test_networks_and_mtu_parse_and_roundtrip`
Expected: FAIL (`NoMethodError: undefined method 'networks'`).

- [ ] **Step 3: Implement**

In `lib/vmctl/config.rb`, add the `Nic` struct after `Disk` and extend `VMEntry`:

```ruby
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options, :mtu, :networks,
    keyword_init: true
  )
  Nic = Struct.new(:bridge, :mtu, :mac, keyword_init: true)
```

In `parse_vm`, add the two members (after `options:`):

```ruby
        options:    parse_options(body.fetch('options', {})),
        mtu:        body['mtu'],
        networks:   parse_networks(body.fetch('networks', []))
```

Add the parser near `parse_options`:

```ruby
    def parse_networks(list)
      list ||= []
      raise ConfigError, "'networks' must be a list" unless list.is_a?(Array)
      list.map do |n|
        raise ConfigError, "each network must be a mapping, got: #{n.inspect}" unless n.is_a?(Hash)
        bridge = n['bridge']
        raise ConfigError, "each network needs a 'bridge', got: #{n.inspect}" if bridge.to_s.empty?
        Nic.new(bridge: bridge, mtu: n['mtu'], mac: n['mac'])
      end
    end
```

In `vm_to_h`, emit the new fields (after the `options` line) and add a `compact_nic` helper:

```ruby
      h['mtu'] = vm.mtu unless vm.mtu.nil?
      h['networks'] = vm.networks.map { |n| compact_nic(n) } unless vm.networks.nil? || vm.networks.empty?
```

```ruby
    def compact_nic(n)
      h = { 'bridge' => n.bridge }
      h['mtu'] = n.mtu unless n.mtu.nil?
      h['mac'] = n.mac unless n.mac.nil?
      h
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "$(printf 'feat(config): add mtu + networks list (Nic) to VMEntry\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 2: index-aware `Allocator#generate_mac`

**Files:**
- Modify: `lib/vmctl/allocator.rb`
- Test: `test/test_allocator.rb`

**Interfaces:**
- Produces: `Allocator#generate_mac(name, index = 0)` — index 0 is byte-identical to the current `generate_mac(name)`; a nonzero index yields a different valid locally-administered MAC.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_allocator.rb`:

```ruby
  def test_generate_mac_index_zero_unchanged
    alloc = VMCtl::Allocator.new(empty_config)
    assert_equal alloc.generate_mac('pod34'), alloc.generate_mac('pod34', 0)
  end

  def test_generate_mac_index_differs_and_valid
    alloc = VMCtl::Allocator.new(empty_config)
    m0 = alloc.generate_mac('pod34', 0)
    m1 = alloc.generate_mac('pod34', 1)
    refute_equal m0, m1
    assert_match(/\A5a:9c:fc(:[0-9a-f]{2}){3}\z/, m1)
  end
```

If `test_allocator.rb` has no `empty_config` helper, add one that builds a `VMCtl::Config` from `"vms: {}\n"` (match the file's existing config-construction style — check the top of the file first).

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_allocator.rb -n test_generate_mac_index_differs_and_valid`
Expected: FAIL (`wrong number of arguments`).

- [ ] **Step 3: Implement**

In `lib/vmctl/allocator.rb`, replace `generate_mac`:

```ruby
    # Deterministic per-(name, index) MAC in the locally-administered range.
    # index 0 is the VM's primary NIC (unchanged); nonzero indexes are additional
    # NICs, seeded distinctly so a VM's NICs never share a generated MAC.
    def generate_mac(name, index = 0)
      seed = index.zero? ? name : "#{name}:nic#{index}"
      digest = Digest::SHA256.hexdigest(seed)
      tail = [digest[0, 2], digest[2, 2], digest[4, 2]].map { |h| h.to_i(16) }
      (OUI + tail).map { |b| format('%02x', b) }.join(':')
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_allocator.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/allocator.rb test/test_allocator.rb
git commit -m "$(printf 'feat(allocator): index-aware generate_mac for per-NIC MACs\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 3: `net_keys` generator + `VM#nic_bridges`/`nic_count`

**Files:**
- Modify: `lib/vmctl/config_renderer.rb`, `lib/vmctl/vm.rb`
- Test: `test/test_config_renderer.rb`, `test/test_vm.rb`

**Interfaces:**
- Consumes: `VMEntry#network/link/mac/mtu/networks` (Task 1).
- Produces: `ConfigRenderer` emits `pci.0.4.N.*` for all NICs (generator appended to the list). `VM#nic_bridges` → Array of bridges to validate (primary unless `none`/nil, plus each `networks:` bridge). `VM#nic_count` → Integer total NICs.

- [ ] **Step 1: Write the failing tests**

First, extend the `entry` helper in `test/test_config_renderer.rb` to accept the new kwargs (keep existing defaults):

```ruby
  def entry(disks:, mac: nil, iso: nil, options: {}, config: 'base.conf',
            network: 'labs_vlan50', mtu: nil, networks: [])
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: network, link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: nil, iso: iso,
      options: options, mtu: mtu, networks: networks
    )
  end
```

Update the existing `test_output_is_sorted` to disable NIC generation so it stays a pure sort test — change its entry to `entry(disks: [], network: 'none')`.

Add these tests:

```ruby
  def test_primary_nic_matches_legacy_keys
    out = render("cpus=2\n", entry(disks: []))
    assert_match(/^pci\.0\.4\.0\.device=virtio-net$/, out)
    assert_match(/^pci\.0\.4\.0\.backend=netgraph$/, out)
    assert_match(/^pci\.0\.4\.0\.path=labs_vlan50:$/, out)
    assert_match(/^pci\.0\.4\.0\.peerhook=link10$/, out)
    assert_match(/^pci\.0\.4\.0\.socket=bhyve_pod34$/, out)
    assert_match(/^pci\.0\.4\.0\.mtu=9000$/, out)
    refute_match(/^pci\.0\.4\.0\.mac=/, out)   # no mac when unset
  end

  def test_primary_mac_and_mtu_override
    out = render("cpus=2\n", entry(disks: [], mac: '5a:9c:fc:00:00:11', mtu: 1500))
    assert_match(/^pci\.0\.4\.0\.mac=5a:9c:fc:00:00:11$/, out)
    assert_match(/^pci\.0\.4\.0\.mtu=1500$/, out)
  end

  def test_additional_nics_get_sequential_functions_and_roles
    nets = [VMCtl::Nic.new(bridge: 'storage_vlan60', mtu: nil, mac: nil),
            VMCtl::Nic.new(bridge: 'mgmt_vlan70', mtu: 1500, mac: '5a:9c:fc:00:00:21')]
    out = render("cpus=2\n", entry(disks: [], networks: nets))
    # nic 1
    assert_match(/^pci\.0\.4\.1\.path=storage_vlan60:$/, out)
    assert_match(/^pci\.0\.4\.1\.peerhook=link10_1$/, out)
    assert_match(/^pci\.0\.4\.1\.socket=bhyve_pod34_1$/, out)
    assert_match(/^pci\.0\.4\.1\.mtu=9000$/, out)
    refute_match(/^pci\.0\.4\.1\.mac=/, out)
    # nic 2
    assert_match(/^pci\.0\.4\.2\.path=mgmt_vlan70:$/, out)
    assert_match(/^pci\.0\.4\.2\.peerhook=link10_2$/, out)
    assert_match(/^pci\.0\.4\.2\.socket=bhyve_pod34_2$/, out)
    assert_match(/^pci\.0\.4\.2\.mtu=1500$/, out)
    assert_match(/^pci\.0\.4\.2\.mac=5a:9c:fc:00:00:21$/, out)
  end

  def test_network_none_omits_primary_and_shifts_functions
    nets = [VMCtl::Nic.new(bridge: 'storage_vlan60', mtu: nil, mac: nil)]
    out = render("cpus=2\n", entry(disks: [], network: 'none', networks: nets))
    # the sole additional NIC takes function 0 (no gap), keeps its role-based name
    assert_match(/^pci\.0\.4\.0\.path=storage_vlan60:$/, out)
    assert_match(/^pci\.0\.4\.0\.peerhook=link10_1$/, out)
    assert_match(/^pci\.0\.4\.0\.socket=bhyve_pod34_1$/, out)
    refute_match(/^pci\.0\.4\.1\./, out)
  end

  def test_network_none_no_networks_has_no_nics
    out = render("cpus=2\n", entry(disks: [], network: 'none'))
    refute_match(/^pci\.0\.4\./, out)
  end
```

Add to `test/test_vm.rb` (extend its `entry` helper with `network:`/`networks:` kwargs the same way, defaulting `network: 'labs_vlan50'`, `networks: []`):

```ruby
  def test_nic_bridges_and_count_primary_only
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal ['labs_vlan50'], vm.nic_bridges
    assert_equal 1, vm.nic_count
  end

  def test_nic_bridges_and_count_with_networks
    nets = [VMCtl::Nic.new(bridge: 'b1', mtu: nil, mac: nil),
            VMCtl::Nic.new(bridge: 'b2', mtu: nil, mac: nil)]
    vm = VMCtl::VM.new(entry(networks: nets), defaults)
    assert_equal %w[labs_vlan50 b1 b2], vm.nic_bridges
    assert_equal 3, vm.nic_count
  end

  def test_nic_bridges_and_count_network_none
    vm = VMCtl::VM.new(entry(network: 'none'), defaults)
    assert_equal [], vm.nic_bridges
    assert_equal 0, vm.nic_count
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n test_additional_nics_get_sequential_functions_and_roles`
Expected: FAIL (no `pci.0.4.*` generated).

- [ ] **Step 3: Implement**

In `lib/vmctl/config_renderer.rb`, append `net_keys` to the generator list and add the methods:

```ruby
    def generators
      [method(:disk_keys), method(:net_keys)]
    end

    def net_keys(vm)
      nics = nic_list(vm)
      keys = {}
      nics.each_with_index do |nic, f|
        p = "pci.0.4.#{f}"
        keys["#{p}.device"]   = 'virtio-net'
        keys["#{p}.backend"]  = 'netgraph'
        keys["#{p}.path"]     = "#{nic[:bridge]}:"
        keys["#{p}.peerhook"] = nic[:peerhook]
        keys["#{p}.socket"]   = nic[:socket]
        keys["#{p}.mtu"]      = (nic[:mtu] || 9000).to_s
        keys["#{p}.mac"]      = nic[:mac] if nic[:mac]
      end
      keys
    end

    # Ordered NIC specs: primary (unless none/nil) then each additional NIC,
    # with role-based peerhook/socket names.
    def nic_list(vm)
      e = vm.entry
      list = []
      unless e.network.nil? || e.network == 'none'
        list << { bridge: e.network, mtu: e.mtu, mac: e.mac,
                  peerhook: "link#{e.link}", socket: "bhyve_#{vm.name}" }
      end
      (e.networks || []).each_with_index do |n, j|
        list << { bridge: n.bridge, mtu: n.mtu, mac: n.mac,
                  peerhook: "link#{e.link}_#{j + 1}", socket: "bhyve_#{vm.name}_#{j + 1}" }
      end
      list
    end
```

In `lib/vmctl/vm.rb`, add:

```ruby
    # Bridges that must exist for this VM (primary unless `none`/nil, plus each
    # additional NIC). Used for start/create validation.
    def nic_bridges
      bridges = []
      bridges << @entry.network unless @entry.network.nil? || @entry.network == 'none'
      (@entry.networks || []).each { |n| bridges << n.bridge }
      bridges
    end

    def nic_count
      primary = (@entry.network.nil? || @entry.network == 'none') ? 0 : 1
      primary + (@entry.networks || []).length
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb && ruby -Ilib -Itest test/test_vm.rb`
Expected: PASS. Then run the full suite — `ruby -Ilib -Itest test/run_all.rb` — and confirm the only change needed elsewhere was `test_output_is_sorted` (now green). Report any other exact-output assertion that newly fails (there should be none; other renderer/command tests use `assert_match`).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config_renderer.rb lib/vmctl/vm.rb test/test_config_renderer.rb test/test_vm.rb
git commit -m "$(printf 'feat: generate pci.0.4.N NICs from inventory (primary + networks)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 4: multi-bridge validation + `none` + NIC cap in create/start

**Files:**
- Modify: `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/start.rb`
- Test: `test/test_create_command.rb`, `test/test_commands.rb`

**Interfaces:**
- Consumes: `VM#nic_bridges`, `VM#nic_count` (Task 3).
- Produces: `create` and `start` validate every NIC bridge and reject > 8 NICs; `network: none` skips primary-bridge validation.

- [ ] **Step 1: Write the failing tests**

In `test/test_create_command.rb` add:

```ruby
  def test_create_network_none_skips_bridge_and_succeeds
    # If create wrongly probed a 'none' bridge, this false probe would make it
    # raise; success proves the primary-bridge check is skipped for `none`.
    exec = FakeExecutor.new(probes: { 'ngctl info none:' => false })
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod37', '--network', 'none']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod37')
    assert_equal 'none', entry.network
  end
```

(If `FakeExecutor` has no `probes_asked?`, drop that last line — the assertion that matters is that a VM with `--network none` is created without a bridge existing.)

In `test/test_commands.rb`, `TestStartCommand`, add a helper that builds a config with additional NICs and tests for multi-bridge validation + cap. Use the existing `config_dir`/`run_dir` fixture style:

```ruby
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_commands.rb -n test_start_validates_every_nic_bridge`
Expected: FAIL (only the primary bridge is probed today).

- [ ] **Step 3: Implement**

In `lib/vmctl/commands/create.rb`, replace the first line of `validate!`:

```ruby
      def validate!(vm, entry, opts, provisioner)
        validate_nics!(vm)
        raise CommandError, "template not found: #{vm.template_path}" unless File.exist?(vm.template_path)
```

and add a private helper (used by both commands — define it here; `start` gets its own copy or a shared one, see below):

```ruby
      def validate_nics!(vm)
        if vm.nic_count > 8
          raise CommandError, "#{vm.name} has #{vm.nic_count} NICs (max 8: pci.0.4.0-7)"
        end
        ng = Netgraph.new(executor)
        vm.nic_bridges.each { |b| ng.ensure_bridge!(b) }
      end
```

In `lib/vmctl/commands/start.rb`, replace the bridge line in `start_one`:

```ruby
        raise CommandError, "#{vm.name} already running" if vm.running?(executor)
        validate_iso_pairing!(vm)
        if vm.nic_count > 8
          raise CommandError, "#{vm.name} has #{vm.nic_count} NICs (max 8: pci.0.4.0-7)"
        end
        vm.nic_bridges.each { |b| @netgraph.ensure_bridge!(b) }
        vm.write_config
```

(`@netgraph` already exists on `Start`.) Note: `create`'s `--network none` now works automatically — `nic_bridges` excludes `none`, so no bridge is probed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_create_command.rb && ruby -Ilib -Itest test/test_commands.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/create.rb lib/vmctl/commands/start.rb test/test_create_command.rb test/test_commands.rb
git commit -m "$(printf 'feat: validate every NIC bridge + 8-NIC cap; --network none in create/start\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 5: migrate example flavors + README

**Files:**
- Modify: `examples/pod.conf`, `examples/pod-installer.conf`, `examples/pod-cloudinit.conf`, `README.md`
- Test: none (run full suite to confirm nothing load-bearing changed).

**Interfaces:** none.

- [ ] **Step 1: Remove the net block from each flavor**

In each of `examples/pod.conf`, `examples/pod-installer.conf`, `examples/pod-cloudinit.conf`, delete the entire `pci.0.4.*` block **including** the commented `#pci.0.4.0.mac=%(mac)` line:

```
pci.0.4.0.device=virtio-net
pci.0.4.0.backend=netgraph
pci.0.4.0.path=%(network):
pci.0.4.0.peerhook=link%(link)
pci.0.4.0.socket=bhyve_%(name)
pci.0.4.0.mtu=9000
#pci.0.4.0.mac=%(mac)
```

Keep everything else (hostbridge, rng `pci.0.20.*`, lpc `pci.0.31.*` + `lpc.com1.path`, any CD `pci.0.5.*`, bootrom, cpus/memory). Update each file's header comment to note that **networking is generated from the inventory (`network` + `networks:`)** and templates must not declare `pci.0.4.*`.

- [ ] **Step 2: Update the README**

Add a networking section (adapt to surrounding prose):

```
Network interfaces are generated by vmctl from the inventory and attached at
pci.0.4.N. The primary NIC comes from `network`/`link`/`mac` (+ optional `mtu`,
default 9000); a `networks:` list adds more (each `{ bridge:, mtu:, mac: }`).
`network: none` gives a console-only VM with no NICs. Templates must NOT declare
`pci.0.4.*`. Per-VM MTU defaults to 9000; `mac: generate` produces a deterministic
per-interface address. Manage NICs with `vmctl add-nic` / `remove-nic`, and the
primary with `vmctl set --network|--mac|--mtu`.
```

- [ ] **Step 3: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS (tests use their own minimal flavors; examples aren't loaded by tests).

- [ ] **Step 4: Commit**

```bash
git add examples/pod.conf examples/pod-installer.conf examples/pod-cloudinit.conf README.md
git commit -m "$(printf 'docs: flavors no longer declare pci.0.4.*; vmctl generates NICs\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 6: `add-nic` command

**Files:**
- Create: `lib/vmctl/commands/add_nic.rb`
- Modify: `lib/vmctl/cli.rb`
- Test: `test/test_add_nic_command.rb`

**Interfaces:**
- Consumes: `vm_for`, `note_next_boot`, `Netgraph#ensure_bridge!`, `Allocator#generate_mac(name, index)`, `VM#nic_count`, `Config#save`.
- Produces: `add-nic <vm> <bridge> [--mtu N] [--mac generate|<addr>]`.

- [ ] **Step 1: Write the failing tests**

Create `test/test_add_nic_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_add_nic_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/add_nic'

class TestAddNicCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped(extra = {}) = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false }.merge(extra))
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_add_nic_appends_and_persists
    exec = stopped('ngctl info storage_vlan60:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'storage_vlan60']) }
    nets = VMCtl::Config.load(@inv).vms.fetch('pod34').networks
    assert_equal 1, nets.length
    assert_equal 'storage_vlan60', nets[0].bridge
    assert_nil nets[0].mtu
    assert_nil nets[0].mac
  end

  def test_add_nic_mtu_and_literal_mac
    exec = stopped('ngctl info b:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'b', '--mtu', '1500', '--mac', '5a:9c:fc:00:00:21']) }
    nic = VMCtl::Config.load(@inv).vms.fetch('pod34').networks[0]
    assert_equal 1500, nic.mtu
    assert_equal '5a:9c:fc:00:00:21', nic.mac
  end

  def test_add_nic_mac_generate_stores_concrete
    exec = stopped('ngctl info b:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'b', '--mac', 'generate']) }
    nic = VMCtl::Config.load(@inv).vms.fetch('pod34').networks[0]
    assert_match(/\A5a:9c:fc(:[0-9a-f]{2}){3}\z/, nic.mac)
  end

  def test_add_nic_rejects_missing_bridge
    exec = stopped('ngctl info nope:' => false)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    assert_raises(VMCtl::NetgraphError) { cmd.call(['pod34', 'nope']) }
  end

  def test_add_nic_rejects_ninth_nic
    nets = (1..7).map { |i| "        - { bridge: b#{i} }" }.join("\n") + "\n"
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
          networks:
      #{nets}
    YAML
    exec = stopped('ngctl info b8:' => true)   # 1 primary + 7 = 8, adding -> 9
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'b8']) }
    assert_match(/max 8/, err.message)
  end

  def test_add_nic_bad_mtu
    exec = stopped('ngctl info b:' => true)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', 'b', '--mtu', 'huge']) }
  end

  def test_add_nic_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true, 'ngctl info b:' => true })
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', 'b']) }
    assert_match(/next start/, out)
  end

  def test_add_nic_dry_run_does_not_persist
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false, 'ngctl info b:' => true }, dry_run: true)
    before = File.read(@inv)
    cmd = VMCtl::Commands::AddNic.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', 'b']) }
    assert_equal before, File.read(@inv)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_add_nic_command.rb -n test_add_nic_appends_and_persists`
Expected: FAIL (`cannot load such file -- vmctl/commands/add_nic`).

- [ ] **Step 3: Implement**

Create `lib/vmctl/commands/add_nic.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/add_nic.rb
require 'optparse'
require_relative 'base'
require_relative '../netgraph'
require_relative '../allocator'

module VMCtl
  module Commands
    # add-nic <vm> <bridge> [--mtu N] [--mac generate|<addr>]
    class AddNic < Base
      MAC_RE = /\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/i.freeze

      def call(args)
        opts = {}
        parser = OptionParser.new do |p|
          p.on('--mtu N')  { |v| opts[:mtu] = v }
          p.on('--mac MAC') { |v| opts[:mac] = v }
        end
        rest = parser.parse(args)
        name, bridge = rest.shift(2)
        raise CommandError, 'add-nic requires <vm> <bridge>' unless name && bridge
        vm = vm_for(name)
        if vm.nic_count >= 8
          raise CommandError, "#{name} already has 8 NICs (max 8: pci.0.4.0-7)"
        end
        Netgraph.new(executor).ensure_bridge!(bridge)
        nic = Nic.new(bridge: bridge, mtu: parse_mtu(opts[:mtu]), mac: resolve_mac(vm, opts[:mac]))
        (vm.entry.networks ||= []) << nic
        config.save(config.path) unless executor.dry_run?
        puts "added nic on #{bridge} (pci.0.4.#{vm.nic_count - 1}) to #{name}"
        note_next_boot(vm, 'the new nic')
      end

      private

      def parse_mtu(v)
        return nil if v.nil?
        n = Integer(v, exception: false)
        raise CommandError, "invalid --mtu #{v.inspect}" if n.nil? || n <= 0
        n
      end

      def resolve_mac(vm, mac)
        return nil if mac.nil?
        return Allocator.new(config).generate_mac(vm.name, (vm.entry.networks || []).length + 1) if mac == 'generate'
        raise CommandError, "invalid --mac #{mac.inspect}" unless mac =~ MAC_RE
        mac
      end
    end
  end
end
```

In `lib/vmctl/cli.rb`: `require_relative 'commands/add_nic'`, register `'add-nic' => Commands::AddNic`, and add a usage line:

```
    add-nic <name> <bridge>  Add a network interface (--mtu N, --mac generate|ADDR).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_add_nic_command.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/add_nic.rb lib/vmctl/cli.rb test/test_add_nic_command.rb
git commit -m "$(printf 'feat: add-nic command to attach a network interface\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 7: `remove-nic` command

**Files:**
- Create: `lib/vmctl/commands/remove_nic.rb`
- Modify: `lib/vmctl/cli.rb`
- Test: `test/test_remove_nic_command.rb`

**Interfaces:**
- Consumes: `vm_for`, `note_next_boot`, `Config#save`.
- Produces: `remove-nic <vm> <index>` — `index` is the 1-based position in `networks:`.

- [ ] **Step 1: Write the failing tests**

Create `test/test_remove_nic_command.rb`:

```ruby
# frozen_string_literal: true
# test/test_remove_nic_command.rb
require 'test_helper'
require 'stringio'
require 'tmpdir'
require 'tempfile'
require 'vmctl/config'
require 'vmctl/commands/remove_nic'

class TestRemoveNicCommand < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @inv = File.join(@dir, 'inventory.yml')
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: labs_vlan50
          link: 10
          disks: [{ file: pod34-root.raw, size: 20G }]
          networks:
            - { bridge: storage_vlan60 }
            - { bridge: mgmt_vlan70 }
    YAML
  end

  def cfg = VMCtl::Config.load(@inv)
  def stopped = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false })
  def capture_stdout
    out = StringIO.new; $stdout = out; yield; out.string
  ensure
    $stdout = STDOUT
  end

  def test_remove_nic_drops_entry
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '1']) }
    nets = VMCtl::Config.load(@inv).vms.fetch('pod34').networks
    assert_equal %w[mgmt_vlan70], nets.map(&:bridge)
  end

  def test_remove_nic_rejects_out_of_range
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '3']) }
    assert_match(/no additional nic/, err.message)
  end

  def test_remove_nic_rejects_zero
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '0']) }
  end

  def test_remove_nic_requires_two_args
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34']) }
  end

  def test_remove_nic_warns_when_running
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => true })
    cmd = VMCtl::Commands::RemoveNic.new(config: cfg, executor: exec)
    out = capture_stdout { cmd.call(['pod34', '1']) }
    assert_match(/next start/, out)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_remove_nic_command.rb -n test_remove_nic_drops_entry`
Expected: FAIL (`cannot load such file`).

- [ ] **Step 3: Implement**

Create `lib/vmctl/commands/remove_nic.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/commands/remove_nic.rb
require_relative 'base'

module VMCtl
  module Commands
    # remove-nic <vm> <index>  -- index is the 1-based position in `networks:`
    # (additional NICs only; the primary is changed via `set --network none`).
    class RemoveNic < Base
      def call(args)
        name, index = args.shift(2)
        raise CommandError, 'remove-nic requires <vm> <index>' unless name && index
        vm = vm_for(name)
        nets = vm.entry.networks || []
        i = Integer(index, exception: false)
        unless i && i >= 1 && i <= nets.length
          raise CommandError, "#{name} has no additional nic ##{index} (has #{nets.length})"
        end
        removed = nets.delete_at(i - 1)
        config.save(config.path) unless executor.dry_run?
        puts "removed nic ##{i} on #{removed.bridge} from #{name}"
        note_next_boot(vm, 'the nic removal')
      end
    end
  end
end
```

In `lib/vmctl/cli.rb`: `require_relative 'commands/remove_nic'`, register `'remove-nic' => Commands::RemoveNic`, and add a usage line:

```
    remove-nic <name> <index>  Remove an additional NIC (1-based networks: index).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_remove_nic_command.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/remove_nic.rb lib/vmctl/cli.rb test/test_remove_nic_command.rb
git commit -m "$(printf 'feat: remove-nic command to detach an additional interface\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 8: `set --mtu` + `set --network none`

**Files:**
- Modify: `lib/vmctl/commands/set.rb`
- Test: `test/test_set_command.rb`

**Interfaces:**
- Produces: `set --mtu N` sets the primary NIC MTU; `set --network none` clears the primary NIC without bridge validation.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_set_command.rb`:

```ruby
  def test_set_mtu
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--mtu', '1500']) }
    assert_equal 1500, VMCtl::Config.load(@inv).vms.fetch('pod34').mtu
  end

  def test_set_bad_mtu
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--mtu', 'huge']) }
  end

  def test_set_network_none_skips_bridge
    # No ngctl probe should be needed; default probes would answer true anyway,
    # so assert the value was set and no bridge lookup gates it.
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--network', 'none']) }
    assert_equal 'none', VMCtl::Config.load(@inv).vms.fetch('pod34').network
  end

  def test_set_network_none_when_bridge_absent
    # Even if every bridge is missing, --network none must succeed.
    exec = FakeExecutor.new(probes: { '/dev/vmm/pod34' => false, 'ngctl info' => false })
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--network', 'none']) }
    assert_equal 'none', VMCtl::Config.load(@inv).vms.fetch('pod34').network
  end
```

(The `test_set_command.rb` `setup`/`cfg`/`stopped` helpers already exist from the Phase 3 `set` tests — reuse them.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_set_command.rb -n test_set_mtu`
Expected: FAIL (no `--mtu` option).

- [ ] **Step 3: Implement**

In `lib/vmctl/commands/set.rb`, add the `--mtu` option to the parser:

```ruby
          p.on('--mtu N')        { |v| opts[:mtu] = v }
```

In `apply!`, add an mtu branch and make the network branch skip validation for `none`:

```ruby
        if opts.key?(:network)
          Netgraph.new(executor).ensure_bridge!(opts[:network]) unless opts[:network] == 'none'
          e.network = opts[:network]
          changed << "network=#{e.network}"
        end
        if opts.key?(:mtu)
          e.mtu = parse_mtu(opts[:mtu])
          changed << "mtu=#{e.mtu}"
        end
```

Add a private helper:

```ruby
      def parse_mtu(v)
        n = Integer(v, exception: false)
        raise CommandError, "invalid --mtu #{v.inspect}" if n.nil? || n <= 0
        n
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_set_command.rb`
Expected: PASS.

- [ ] **Step 5: Run the FULL suite + commit**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS (entire suite).

```bash
git add lib/vmctl/commands/set.rb test/test_set_command.rb
git commit -m "$(printf 'feat(set): --mtu for primary NIC and --network none\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] Full suite: `ruby -Ilib -Itest test/run_all.rb` → all PASS.
- [ ] CLI help lists the new commands: `ruby -Ilib bin/vmctl help` shows `add-nic`/`remove-nic` and `set` mentions `--mtu`.
- [ ] `git log --oneline` shows the 8 task commits on `feat/multi-nic`.

## Notes for the implementer

- `FakeExecutor#success?` returns `true` for unspecified probes — set `'/dev/vmm/<name>' => false` for a "stopped" VM and `'ngctl info <bridge>:' => true/false` to model a present/absent bridge.
- Only gate `config.save` behind `unless executor.dry_run?`; `Executor#run` already no-ops under dry-run.
- `Nic` is a `Struct`, so `nic.mtu = ...` mutates in place; append with `entry.networks << nic`. Loaded VMs always have `networks == []` (never nil) because `parse_networks` defaults to `[]`; the `||= []` guards the freshly-built-entry case.
- The primary NIC's generated `pci.0.4.0.*` keys are byte-identical to the old template's active lines for a single-NIC VM — `test_primary_nic_matches_legacy_keys` is the regression guard.
