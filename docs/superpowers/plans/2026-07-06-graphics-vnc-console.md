# Graphics / VNC Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-VM `graphics: true/false` inventory field that generates a bhyve `fbuf` (VNC framebuffer) console plus an `xhci`+`tablet` USB pointer, with the VNC port derived from the VM's `link` and the bind address from host-wide defaults.

**Architecture:** Follows the established "generated keys win" seam. A new `graphics_keys` generator is appended to `ConfigRenderer`'s generator list (exactly like `hardware_keys`); it emits `fbuf`/`xhci` keys only when the entry's `graphics` flag is set. The VNC port is `vnc_base + link` (link is already globally unique), and the socket binds to `vnc_bind` — both new `defaults:` knobs. `create`/`set` gain a boolean `--graphics`/`--no-graphics` flag (mirroring `--autostart`), and `status` prints the VNC endpoint for graphics-enabled VMs.

**Tech Stack:** Pure Ruby (stdlib only, no gems). minitest. Module namespace `VMCtl`.

## Global Constraints

- **Ruby stdlib only** — no gems, ever.
- **Run the full suite with:** `ruby -Ilib -Itest test/run_all.rb` (run from repo root).
- **Run one test file with:** `ruby -Ilib -Itest test/<file>.rb`; one method with `-n test_name`.
- **Module namespace:** `VMCtl`. Structs use `keyword_init: true`.
- **Generated keys win** — generators run last in `ConfigRenderer#render`, overriding the flavor file and the `options:` map.
- **`vnc_base` default = `5900`; `vnc_bind` default = `'0.0.0.0'`; VNC port = `vnc_base + link`.**
- **fbuf on PCI slot `pci.0.7.0`; xhci+tablet on `pci.0.8.0`** (both currently free).
- **Resolution fixed at `1024`×`768`; `wait=false`** (not configurable — YAGNI).
- **`graphics` is a plain boolean**; when false/absent it is omitted from `vm_to_h` output (existing inventories stay byte-stable).
- **Commit after each task** once its tests pass. Commit message trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tw1uWUsKMXsnLErXaGuHRq
  ```
  (git writes in this repo are sandbox-denied; commit with the sandbox disabled.)

## File Structure

- `lib/vmctl/config.rb` — add `:graphics` to `VMEntry`; add `:vnc_base`/`:vnc_bind` to `Defaults` + `DEFAULTS`; parse + round-trip. (Task 1)
- `lib/vmctl/vm.rb` — add `vnc_port` / `vnc_endpoint` helpers. (Task 2)
- `lib/vmctl/config_renderer.rb` — add `graphics_keys` generator, append to `generators`. (Task 3)
- `lib/vmctl/commands/status.rb` — append VNC endpoint for graphics VMs. (Task 4)
- `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/set.rb`, `lib/vmctl/cli.rb` — `--graphics`/`--no-graphics` flags + usage line. (Task 5)
- `README.md`, `examples/inventory.yml` — document the field, defaults, and the unauthenticated-console caveat. (Task 6)
- Tests: `test/test_config.rb`, `test/test_vm.rb`, `test/test_config_renderer.rb`, `test/test_commands.rb`, `test/test_create_command.rb`, `test/test_set_command.rb`.

---

### Task 1: Schema — `graphics` field + `vnc_base`/`vnc_bind` defaults

**Files:**
- Modify: `lib/vmctl/config.rb` (structs, `DEFAULTS`, `parse_defaults`, `parse_vm`, `vm_to_h`)
- Test: `test/test_config.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `VMEntry#graphics` — boolean (`false` when absent).
  - `Defaults#vnc_base` — Integer (default `5900`).
  - `Defaults#vnc_bind` — String (default `'0.0.0.0'`).
  - `vm_to_h` emits `'graphics' => true` only when the entry's `graphics` is truthy.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config.rb` (inside `class TestConfig`):

```ruby
  def test_vnc_defaults_fill_in
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal 5900, cfg.defaults.vnc_base
    assert_equal '0.0.0.0', cfg.defaults.vnc_bind
    f.close
  end

  def test_vnc_defaults_override
    f = write_inventory(<<~YAML)
      defaults: { vnc_base: 6000, vnc_bind: 127.0.0.1 }
      vms: {}
    YAML
    cfg = VMCtl::Config.load(f.path)
    assert_equal 6000, cfg.defaults.vnc_base
    assert_equal '127.0.0.1', cfg.defaults.vnc_bind
    f.close
  end

  def test_bad_vnc_base_raises
    f = write_inventory("defaults: { vnc_base: nope }\nvms: {}\n")
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(f.path) }
    f.close
  end

  def test_graphics_parsed_and_defaults_false
    f = write_inventory(<<~YAML)
      vms:
        g1: { network: n, link: 10, graphics: true }
        g2: { network: n, link: 11 }
    YAML
    cfg = VMCtl::Config.load(f.path)
    assert_equal true, cfg.vms.fetch('g1').graphics
    assert_equal false, cfg.vms.fetch('g2').graphics
    f.close
  end

  def test_graphics_round_trips_only_when_true
    f = write_inventory(<<~YAML)
      vms:
        g1: { network: n, link: 10, graphics: true, disks: [] }
        g2: { network: n, link: 11, disks: [] }
    YAML
    cfg = VMCtl::Config.load(f.path)
    h = cfg.to_h
    assert_equal true, h['vms']['g1']['graphics']
    refute h['vms']['g2'].key?('graphics'), 'graphics omitted when false'
    f.close
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/vnc|graphics/"`
Expected: FAIL (e.g. `NoMethodError: undefined method 'vnc_base'` / graphics assertions fail).

- [ ] **Step 3: Implement the schema changes**

In `lib/vmctl/config.rb`:

Add `:graphics` to the `VMEntry` struct member list (after `:memory`):

```ruby
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options, :mtu, :networks, :cpus, :memory, :graphics,
    keyword_init: true
  )
```

Add `:vnc_base, :vnc_bind` to the `Defaults` struct member list (after `:memory`):

```ruby
  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from, :cpus, :memory, :vnc_base, :vnc_bind,
    keyword_init: true
  )
```

Add two keys to `DEFAULTS` (after `'memory' => '1G'`):

```ruby
      'memory'     => '1G',
      'vnc_base'   => 5900,
      'vnc_bind'   => '0.0.0.0'
```

In `parse_defaults`, add the two fields to the `Defaults.new(...)` call (after `memory:`):

```ruby
        cpus:       parse_cpus(merged['cpus']),
        memory:     parse_memory(merged['memory']),
        vnc_base:   parse_vnc_base(merged['vnc_base']),
        vnc_bind:   merged['vnc_bind']
```

In `parse_vm`, add `graphics:` to the `VMEntry.new(...)` call (after `memory:`):

```ruby
        cpus:       parse_cpus(body['cpus']),
        memory:     parse_memory(body['memory']),
        graphics:   body.fetch('graphics', false)
```

Add a `parse_vnc_base` helper (place next to `parse_link_base`):

```ruby
    def parse_vnc_base(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ConfigError, "'vnc_base' must be an integer, got: #{value.inspect}"
    end
```

In `vm_to_h`, emit `graphics` only when truthy (add after the `memory` line):

```ruby
      h['cpus'] = vm.cpus unless vm.cpus.nil?
      h['memory'] = vm.memory unless vm.memory.nil?
      h['graphics'] = true if vm.graphics
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/vnc|graphics/"`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite (catches struct-shape regressions)**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green. (Adding trailing struct members is backward-compatible; existing `Defaults.new`/`VMEntry.new` calls omit them and get `nil`.)

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "feat(config): graphics VM field + vnc_base/vnc_bind defaults"
```

---

### Task 2: `VM#vnc_port` / `VM#vnc_endpoint` helpers

**Files:**
- Modify: `lib/vmctl/vm.rb`
- Test: `test/test_vm.rb` (update the `defaults` helper; add tests)

**Interfaces:**
- Consumes: `Defaults#vnc_base`, `Defaults#vnc_bind` (Task 1); `entry.link`.
- Produces:
  - `VM#vnc_port` → Integer (`vnc_base + link`).
  - `VM#vnc_endpoint` → String (`"<vnc_bind>:<vnc_port>"`).

- [ ] **Step 1: Update the test `defaults` helper and write failing tests**

In `test/test_vm.rb`, update the `defaults` helper to include the new fields (add to the `VMCtl::Defaults.new(...)` call, after `cpus: 1, memory: '1G'`):

```ruby
      run_dir: run_dir, log_dir: '/var/log/vmctl',
      cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0'
```

Add these tests to `class TestVM`:

```ruby
  def test_vnc_port_is_base_plus_link
    vm = VMCtl::VM.new(entry, defaults)   # link 10
    assert_equal 5910, vm.vnc_port
  end

  def test_vnc_endpoint_combines_bind_and_port
    vm = VMCtl::VM.new(entry, defaults)
    assert_equal '0.0.0.0:5910', vm.vnc_endpoint
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_vm.rb -n "/vnc/"`
Expected: FAIL (`NoMethodError: undefined method 'vnc_port'`).

- [ ] **Step 3: Implement the helpers**

In `lib/vmctl/vm.rb`, add after `console_device` (around line 64):

```ruby
    def vnc_port
      @defaults.vnc_base + @entry.link
    end

    def vnc_endpoint
      "#{@defaults.vnc_bind}:#{vnc_port}"
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_vm.rb -n "/vnc/"`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/vm.rb test/test_vm.rb
git commit -m "feat(vm): vnc_port/vnc_endpoint helpers (vnc_base + link)"
```

---

### Task 3: `graphics_keys` generator

**Files:**
- Modify: `lib/vmctl/config_renderer.rb`
- Test: `test/test_config_renderer.rb` (update the `defaults` helper; add tests)

**Interfaces:**
- Consumes: `entry.graphics` (Task 1); `VM#vnc_endpoint` (Task 2).
- Produces: `fbuf` keys on `pci.0.7.0` and `xhci`+`tablet` keys on `pci.0.8.0`, generated last so they win over the flavor + `options:`.

- [ ] **Step 1: Update the test `defaults` helper and write failing tests**

In `test/test_config_renderer.rb`, update the `defaults` helper's `VMCtl::Defaults.new(...)` (after `cpus: 1, memory: '1G'`):

```ruby
      run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl',
      cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0'
```

Update the `entry` helper signature to accept `graphics:` and pass it through:

```ruby
  def entry(disks:, mac: nil, iso: nil, cloud_init: nil, options: {}, config: 'base.conf',
            network: 'labs_vlan50', mtu: nil, networks: [], cpus: nil, memory: nil,
            graphics: false)
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: network, link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: cloud_init, iso: iso,
      options: options, mtu: mtu, networks: networks, cpus: cpus, memory: memory,
      graphics: graphics
    )
  end
```

Add these tests to `class TestConfigRenderer`:

```ruby
  def test_no_graphics_keys_when_disabled
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.7\./, out)
    refute_match(/pci\.0\.8\./, out)
  end

  def test_graphics_generates_fbuf_and_tablet
    out = render("cpus=2\n", entry(disks: [], graphics: true))
    assert_match(/^pci\.0\.7\.0\.device=fbuf$/, out)
    assert_match(/^pci\.0\.7\.0\.tcp=0\.0\.0\.0:5910$/, out)   # vnc_base 5900 + link 10
    assert_match(/^pci\.0\.7\.0\.w=1024$/, out)
    assert_match(/^pci\.0\.7\.0\.h=768$/, out)
    assert_match(/^pci\.0\.7\.0\.wait=false$/, out)
    assert_match(/^pci\.0\.8\.0\.device=xhci$/, out)
    assert_match(/^pci\.0\.8\.0\.slot\.1\.device=tablet$/, out)
  end

  def test_graphics_port_tracks_bind_from_defaults
    # Render with a loopback bind + custom base to prove the endpoint is data-driven.
    Dir.mktmpdir do |dir|
      e = entry(disks: [], graphics: true)
      File.write(File.join(dir, e.config), "cpus=2\n")
      d = VMCtl::Defaults.new(
        config_dir: dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
        template: 'base.conf', link_base: 10,
        run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl',
        cpus: 1, memory: '1G', vnc_base: 6000, vnc_bind: '127.0.0.1'
      )
      vm = VMCtl::VM.new(e, d)
      out = VMCtl::ConfigRenderer.new(d).render(vm)
      assert_match(/^pci\.0\.7\.0\.tcp=127\.0\.0\.1:6010$/, out)
    end
  end

  def test_graphics_keys_beat_options
    e = entry(disks: [], graphics: true, options: { 'pci.0.7.0.device' => 'evil' })
    out = render("cpus=2\n", e)
    assert_match(/^pci\.0\.7\.0\.device=fbuf$/, out)
    refute_match(/evil/, out)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/graphics/"`
Expected: FAIL (no `pci.0.7.*` keys emitted).

- [ ] **Step 3: Implement the generator**

In `lib/vmctl/config_renderer.rb`, append `graphics_keys` to the `generators` list:

```ruby
    def generators
      [method(:disk_keys), method(:net_keys), method(:iso_cd_keys),
       method(:seed_cd_keys), method(:hardware_keys), method(:graphics_keys)]
    end
```

Add the generator method (place it right after `hardware_keys`):

```ruby
    # VNC framebuffer + USB tablet pointer, generated when graphics: true.
    # Port derives from the VM's (unique) link; bind address is a host default.
    def graphics_keys(vm)
      return {} unless vm.entry.graphics
      {
        'pci.0.7.0.device'        => 'fbuf',
        'pci.0.7.0.tcp'           => vm.vnc_endpoint,
        'pci.0.7.0.w'             => '1024',
        'pci.0.7.0.h'             => '768',
        'pci.0.7.0.wait'          => 'false',
        'pci.0.8.0.device'        => 'xhci',
        'pci.0.8.0.slot.1.device' => 'tablet'
      }
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/graphics/"`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/config_renderer.rb test/test_config_renderer.rb
git commit -m "feat(renderer): graphics_keys generator (fbuf + xhci tablet)"
```

---

### Task 4: `status` prints the VNC endpoint for graphics VMs

**Files:**
- Modify: `lib/vmctl/commands/status.rb`
- Test: `test/test_commands.rb` (add tests to `class TestStatusCommand`)

**Interfaces:**
- Consumes: `entry.graphics` (Task 1); `VM#vnc_endpoint` (Task 2).
- Produces: appends `vnc <endpoint>` to each status line for graphics-enabled VMs only.

- [ ] **Step 1: Write the failing tests**

The shared `inventory` in `test/test_commands.rb` defines `pod34` without graphics. Add a graphics-enabled inventory + tests to `class TestStatusCommand`:

```ruby
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_commands.rb -n "/vnc/"`
Expected: FAIL (`test_status_shows_vnc_endpoint_for_graphics_vm` — no `vnc` in output).

- [ ] **Step 3: Implement the status suffix**

In `lib/vmctl/commands/status.rb`, build a `vnc` suffix and append it to `net`:

```ruby
      def call(args)
        all = args.delete('--all')
        vms = targets(args, all: all || args.empty?)
        vms.each do |vm|
          net = "(#{vm.entry.network} link #{vm.entry.link})"
          net = "#{net} vnc #{vm.vnc_endpoint}" if vm.entry.graphics
          if !vm.running?(executor)
            puts "#{vm.name}: stopped #{net}"
          elsif vm.supervisor_alive?(executor)
            puts "#{vm.name}: running pid #{vm.read_pid} #{net}"
          else
            puts "#{vm.name}: stale — vmm device with no live supervisor; " \
                 "run 'vmctl stop --force #{vm.name}' #{net}"
          end
        end
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_commands.rb -n "/vnc/"`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/commands/status.rb test/test_commands.rb
git commit -m "feat(status): show VNC endpoint for graphics-enabled VMs"
```

---

### Task 5: CLI — `create --graphics` / `set --graphics` / `set --no-graphics`

**Files:**
- Modify: `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/set.rb`, `lib/vmctl/cli.rb`
- Test: `test/test_create_command.rb`, `test/test_set_command.rb`

**Interfaces:**
- Consumes: `VMEntry#graphics` (Task 1).
- Produces: `create --graphics` sets `entry.graphics = true`; `set --graphics`/`--no-graphics` toggles it.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_create_command.rb` (`class TestCreateCommand`):

```ruby
  def test_create_with_graphics
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--graphics']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod35').graphics
  end

  def test_create_without_graphics_defaults_false
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod35').graphics
  end
```

Add to `test/test_set_command.rb` (`class TestSetCommand`):

```ruby
  def test_set_graphics
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--graphics']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').graphics
  end

  def test_set_no_graphics
    File.write(@inv, <<~YAML)
      defaults: { config_dir: #{@dir}, vm_root: /bhyve, zpool: tank, link_base: 10 }
      vms:
        pod34:
          config: pod.conf
          network: labs_vlan50
          link: 10
          graphics: true
          disks: [{ file: pod34-root.raw, size: 20G }]
    YAML
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-graphics']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').graphics
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_create_command.rb -n "/graphics/" && ruby -Ilib -Itest test/test_set_command.rb -n "/graphics/"`
Expected: FAIL (`--graphics` is an unknown option / value not set).

- [ ] **Step 3: Implement `create --graphics`**

In `lib/vmctl/commands/create.rb`, add the flag to `parse` (after the `--autostart` line):

```ruby
          p.on('--autostart')   { o[:autostart] = true }
          p.on('--graphics')    { o[:graphics] = true }
          p.on('--start')       { o[:start] = true }
```

Add `graphics:` to the `VMEntry.new(...)` in `build_entry` (after `memory:`):

```ruby
          cpus: opts[:cpus] && positive_int!(opts[:cpus], '--cpus'),
          memory: opts[:memory] && valid_size!(opts[:memory], '--memory'),
          graphics: !!opts[:graphics]
```

- [ ] **Step 4: Implement `set --graphics` / `--no-graphics`**

In `lib/vmctl/commands/set.rb`, add the flags to the `OptionParser` block (after the `--no-autostart` line):

```ruby
          p.on('--autostart')    { opts[:autostart] = true }
          p.on('--no-autostart') { opts[:autostart] = false }
          p.on('--graphics')     { opts[:graphics] = true }
          p.on('--no-graphics')  { opts[:graphics] = false }
```

Add the apply clause in `apply!` (after the `autostart` clause):

```ruby
        if opts.key?(:graphics)
          e.graphics = opts[:graphics]
          changed << "graphics=#{e.graphics}"
        end
```

- [ ] **Step 5: Update the CLI usage line**

In `lib/vmctl/cli.rb`, update the `set` usage line to list the new flag (add `/--graphics` before `/--config`):

```ruby
        set <name> [opts]       Change VM fields (--autostart/--network[ none]/--mac/--mtu/--cpus/--memory/--graphics/--config/--iso/--cloud-init/--var/--no-cloud-init).
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_create_command.rb -n "/graphics/" && ruby -Ilib -Itest test/test_set_command.rb -n "/graphics/"`
Expected: PASS (4 tests).

- [ ] **Step 7: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add lib/vmctl/commands/create.rb lib/vmctl/commands/set.rb lib/vmctl/cli.rb \
        test/test_create_command.rb test/test_set_command.rb
git commit -m "feat(cli): create/set --graphics flag"
```

---

### Task 6: Docs — README + example inventory

**Files:**
- Modify: `README.md`, `examples/inventory.yml`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add the `graphics` field + `vnc_*` defaults to the example inventory**

In `examples/inventory.yml`, add `vnc_base`/`vnc_bind` under `defaults:` (only if the file lists other defaults; match its existing style) and add a commented `graphics: true` example to one VM entry, e.g.:

```yaml
    # graphics: true   # attach a VNC console (fbuf) + USB tablet;
    #                  # reachable at <vnc_bind>:<vnc_base + link>
```

Read the current `examples/inventory.yml` first and mirror its exact indentation/comment style. If the file has no `defaults:` block, add only the per-VM commented example.

- [ ] **Step 2: Document the feature in the README**

In `README.md`, add a short subsection near the other inventory fields (disks/NICs/cpus/memory). Include:

- `graphics: true` on a VM attaches a bhyve `fbuf` VNC console plus an `xhci`+`tablet` USB pointer.
- The VNC port is `vnc_base + link` (defaults: `vnc_base: 5900`, so `link 10` → port `5910`).
- The socket binds to `vnc_bind` (**default `0.0.0.0`** — reachable from any host that can route to the bhyve host).
- **Security caveat:** bhyve's VNC console is **unauthenticated**. To restrict access, set `defaults.vnc_bind: 127.0.0.1` and tunnel: `ssh -L 5910:localhost:5910 <host>`, then point a VNC client at `localhost:5910`.
- `status` prints the VNC endpoint for graphics-enabled VMs.

Read the README's existing structure first and match its heading level and prose style.

- [ ] **Step 3: Run the full suite (docs shouldn't break anything, but confirm)**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add README.md examples/inventory.yml
git commit -m "docs: document graphics/VNC console field + vnc_* defaults"
```

---

## Self-Review

**Spec coverage:**
- `graphics` field on `VMEntry` → Task 1. ✓
- `vnc_base`/`vnc_bind` defaults (5900 / 0.0.0.0) + `Config::DEFAULTS` → Task 1. ✓
- `vm_to_h` emits `graphics` only when true → Task 1. ✓
- `parse_vnc_base` validation / `ConfigError` on bad `vnc_base` → Task 1. ✓
- `VM#vnc_port` / `vnc_endpoint` → Task 2. ✓
- `graphics_keys` generator (fbuf `pci.0.7`, xhci+tablet `pci.0.8`, port from link, bind from defaults, wins over options) → Task 3. ✓
- Status shows VNC endpoint for graphics VMs only → Task 4. ✓
- `create --graphics`, `set --graphics`/`--no-graphics`, CLI usage line → Task 5. ✓
- README + example inventory (incl. unauthenticated-console caveat) → Task 6. ✓
- Resolution fixed 1024×768, `wait=false` → Task 3 (hardcoded). ✓
- No migration / no template changes → confirmed (new PCI slots only). ✓

**Placeholder scan:** No TBD/TODO; all steps carry concrete code and commands. Task 6 intentionally instructs "read the file and match its style" because the README/example structure isn't reproduced here — but the required *content* is fully enumerated, so there is no missing decision.

**Type consistency:** `graphics` is a boolean everywhere (`entry.graphics`, `opts[:graphics]`, `body.fetch('graphics', false)`, `!!opts[:graphics]`). `vnc_base` is Integer, `vnc_bind` is String, `vnc_port` returns Integer, `vnc_endpoint` returns String. Generator key names (`pci.0.7.0.*`, `pci.0.8.0.*`) match the tests in Task 3 and the design spec. `vnc_endpoint` is defined in Task 2 and consumed in Tasks 3 and 4.
