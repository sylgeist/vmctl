# Guest-Tuning Fields Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two guest-tuning inventory fields — `rtc_localtime` (controls `rtc.use_localtime`) and `memory_wired` (controls `memory.wired`) — generated into the bhyve config.

**Architecture:** `rtc_localtime` follows the cpus/memory pattern (a `defaults` knob + per-VM override, always emitted); `memory_wired` is a per-VM opt-in boolean (emitted only when true). Both are produced by a single new `tuning_keys` generator appended last to `ConfigRenderer`'s generator list.

**Tech Stack:** Pure Ruby (stdlib only, no gems). minitest. Module namespace `VMCtl`.

## Global Constraints

- **Ruby stdlib only** — no gems, ever.
- **Run the full suite with:** `ruby -Ilib -Itest test/run_all.rb` (from repo root).
- **Run one test file with:** `ruby -Ilib -Itest test/<file>.rb`; one method/pattern with `-n "/pattern/"`.
- **Module namespace:** `VMCtl`. Structs use `keyword_init: true`; new members appended at the END of the member list (backward-compatible).
- **Generated keys win** — generators run last in `ConfigRenderer#resolve`, overriding the flavor file and the `options:` map.
- **`rtc_localtime` default = `true`** (matches bhyve's localtime). **`memory_wired` has no default** (per-VM opt-in, absent → not emitted).
- **`rtc.use_localtime` is ALWAYS emitted**; entry-vs-default resolution uses a `.nil?` check, **never `||`** (an explicit `false` must not be treated as unset).
- **`memory.wired=true` is emitted ONLY when `memory_wired` is truthy.**
- **`vm_to_h` emits `rtc_localtime` only when non-nil (true OR false), and `memory_wired` only when true** (existing inventories stay byte-stable).
- **Commit after each task** once its tests pass. git writes in this repo are sandbox-denied — set `dangerouslyDisableSandbox: true` on the commit Bash call. Commit trailer (blank line before it):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tw1uWUsKMXsnLErXaGuHRq
  ```

## File Structure

- `lib/vmctl/config.rb` — `rtc_localtime`/`memory_wired` on `VMEntry`; `rtc_localtime` on `Defaults`+`DEFAULTS`; parse + round-trip. (Task 1)
- `lib/vmctl/config_renderer.rb` — `tuning_keys` generator. (Task 2)
- `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/set.rb`, `lib/vmctl/cli.rb` — CLI flags + usage. (Task 3)
- `README.md`, `examples/inventory.yml` — document both fields. (Task 4)
- Tests: `test/test_config.rb`, `test/test_config_renderer.rb`, `test/test_vm.rb`, `test/test_create_command.rb`, `test/test_set_command.rb`.

---

### Task 1: Schema — `rtc_localtime` + `memory_wired` fields

**Files:**
- Modify: `lib/vmctl/config.rb`
- Test: `test/test_config.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `VMEntry#rtc_localtime` — boolean or `nil` (nil when unset).
  - `VMEntry#memory_wired` — boolean (`false` when absent).
  - `Defaults#rtc_localtime` — boolean (default `true`).
  - `vm_to_h` emits `rtc_localtime` when non-nil, `memory_wired` when true.

- [ ] **Step 1: Write the failing tests**

Add to `class TestConfig` in `test/test_config.rb`:

```ruby
  def test_rtc_localtime_default_true
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal true, cfg.defaults.rtc_localtime
    f.close
  end

  def test_rtc_localtime_default_override
    f = write_inventory("defaults: { rtc_localtime: false }\nvms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal false, cfg.defaults.rtc_localtime
    f.close
  end

  def test_vm_rtc_localtime_parsed_nil_when_absent
    f = write_inventory(<<~YAML)
      vms:
        a: { network: n, link: 10, rtc_localtime: false }
        b: { network: n, link: 11, rtc_localtime: true }
        c: { network: n, link: 12 }
    YAML
    cfg = VMCtl::Config.load(f.path)
    assert_equal false, cfg.vms.fetch('a').rtc_localtime
    assert_equal true, cfg.vms.fetch('b').rtc_localtime
    assert_nil cfg.vms.fetch('c').rtc_localtime
    f.close
  end

  def test_memory_wired_parsed_and_defaults_false
    f = write_inventory(<<~YAML)
      vms:
        a: { network: n, link: 10, memory_wired: true }
        b: { network: n, link: 11 }
    YAML
    cfg = VMCtl::Config.load(f.path)
    assert_equal true, cfg.vms.fetch('a').memory_wired
    assert_equal false, cfg.vms.fetch('b').memory_wired
    f.close
  end

  def test_tuning_fields_round_trip
    f = write_inventory(<<~YAML)
      vms:
        a: { network: n, link: 10, rtc_localtime: false, memory_wired: true, disks: [] }
        b: { network: n, link: 11, disks: [] }
    YAML
    cfg = VMCtl::Config.load(f.path)
    h = cfg.to_h
    assert_equal false, h['vms']['a']['rtc_localtime']  # false still emitted (non-nil)
    assert_equal true, h['vms']['a']['memory_wired']
    refute h['vms']['b'].key?('rtc_localtime'), 'rtc_localtime omitted when unset'
    refute h['vms']['b'].key?('memory_wired'), 'memory_wired omitted when false'
    f.close
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/rtc_localtime|memory_wired|tuning/"`
Expected: FAIL (`NoMethodError: undefined method 'rtc_localtime'` / assertions fail).

- [ ] **Step 3: Implement the schema changes**

In `lib/vmctl/config.rb`:

Append `:rtc_localtime, :memory_wired` to the `VMEntry` struct member list (after `:efi_vars`):

```ruby
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options, :mtu, :networks, :cpus, :memory, :graphics, :efi_vars,
    :rtc_localtime, :memory_wired,
    keyword_init: true
  )
```

Append `:rtc_localtime` to the `Defaults` struct member list (after `:uefi_vars_template`):

```ruby
  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from, :cpus, :memory, :vnc_base, :vnc_bind,
    :uefi_vars_template, :rtc_localtime,
    keyword_init: true
  )
```

Add the default to `DEFAULTS` (after the `uefi_vars_template` entry):

```ruby
      'uefi_vars_template' => '/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd',
      'rtc_localtime' => true
```

In `parse_defaults`, add to the `Defaults.new(...)` call (after `uefi_vars_template:`):

```ruby
        uefi_vars_template: merged['uefi_vars_template'],
        rtc_localtime: merged['rtc_localtime']
```

In `parse_vm`, add to the `VMEntry.new(...)` call (after `efi_vars:`):

```ruby
        efi_vars:   body.fetch('efi_vars', false),
        rtc_localtime: body.key?('rtc_localtime') ? body['rtc_localtime'] : nil,
        memory_wired:  body.fetch('memory_wired', false)
```

In `vm_to_h`, emit both (add after the `efi_vars` line):

```ruby
      h['efi_vars'] = true if vm.efi_vars
      h['rtc_localtime'] = vm.rtc_localtime unless vm.rtc_localtime.nil?
      h['memory_wired'] = true if vm.memory_wired
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb -n "/rtc_localtime|memory_wired|tuning/"`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green. (Trailing struct members are backward-compatible; no generator emits the keys yet, so rendered output is unchanged.)

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "feat(config): rtc_localtime + memory_wired VM fields; rtc_localtime default"
```

---

### Task 2: `tuning_keys` generator

**Files:**
- Modify: `lib/vmctl/config_renderer.rb`
- Test: `test/test_config_renderer.rb`, `test/test_vm.rb`

**Interfaces:**
- Consumes: `entry.rtc_localtime`, `entry.memory_wired` (Task 1); `Defaults#rtc_localtime` (Task 1).
- Produces: `tuning_keys(vm)` emits `rtc.use_localtime` always and `memory.wired=true` when `memory_wired`.

- [ ] **Step 1: Update test helpers, then write failing tests**

**1a.** In `test/test_config_renderer.rb`, add `rtc_localtime: true` to the `defaults` helper's `Defaults.new(...)` (after `vnc_base: 5900, vnc_bind: '0.0.0.0'`), and to the inline `Defaults.new(...)` inside `test_graphics_port_tracks_bind_from_defaults`:

```ruby
      cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0',
      rtc_localtime: true
```

Update the `entry` helper signature to accept `rtc_localtime:`/`memory_wired:` and pass them through:

```ruby
  def entry(disks:, mac: nil, iso: nil, cloud_init: nil, options: {}, config: 'base.conf',
            network: 'labs_vlan50', mtu: nil, networks: [], cpus: nil, memory: nil,
            graphics: false, efi_vars: false, rtc_localtime: nil, memory_wired: false)
    VMCtl::VMEntry.new(
      name: 'pod34', config: config, network: network, link: 10,
      mac: mac, autostart: true, disks: disks, cloud_init: cloud_init, iso: iso,
      options: options, mtu: mtu, networks: networks, cpus: cpus, memory: memory,
      graphics: graphics, efi_vars: efi_vars, rtc_localtime: rtc_localtime,
      memory_wired: memory_wired
    )
  end
```

**1b.** In `test/test_vm.rb`, add `rtc_localtime: true` to the `defaults` helper's `Defaults.new(...)` (after `vnc_base: 5900, vnc_bind: '0.0.0.0'`) and to both inline `Defaults.new(...)` calls (in `test_render_and_write_config` and `test_resolved_config_is_a_map`), each after their `cpus:`/`memory:`/`vnc_*` args:

```ruby
      cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0', rtc_localtime: true
```

**1c.** Update the existing exact-output test `test_output_is_sorted` in `test/test_config_renderer.rb` to include the always-emitted `rtc.use_localtime=true` line (sorted between `memory.size=1G` and `zeta=1`):

```ruby
  def test_output_is_sorted
    out = render("zeta=1\nalpha=2\n", entry(disks: [], network: 'none'))
    assert_equal %w[alpha=2 cpus=1 memory.size=1G rtc.use_localtime=true zeta=1], out.split("\n")
  end
```

**1d.** Add new renderer tests to `class TestConfigRenderer`:

```ruby
  def test_rtc_localtime_defaults_to_true
    out = render("cpus=2\n", entry(disks: []))               # entry rtc nil -> default true
    assert_match(/^rtc\.use_localtime=true$/, out)
  end

  def test_rtc_localtime_entry_false_is_honored
    out = render("cpus=2\n", entry(disks: [], rtc_localtime: false))
    assert_match(/^rtc\.use_localtime=false$/, out)          # explicit false, not the default
    refute_match(/^rtc\.use_localtime=true$/, out)
  end

  def test_rtc_localtime_falls_back_to_defaults_false
    # entry nil, but defaults say localtime=false -> renders false
    Dir.mktmpdir do |dir|
      e = entry(disks: [])
      File.write(File.join(dir, e.config), "cpus=2\n")
      d = VMCtl::Defaults.new(
        config_dir: dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
        template: 'base.conf', link_base: 10,
        run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl',
        cpus: 1, memory: '1G', vnc_base: 5900, vnc_bind: '0.0.0.0',
        rtc_localtime: false
      )
      vm = VMCtl::VM.new(e, d)
      out = VMCtl::ConfigRenderer.new(d).render(vm)
      assert_match(/^rtc\.use_localtime=false$/, out)
    end
  end

  def test_memory_wired_emitted_only_when_true
    on  = render("cpus=2\n", entry(disks: [], memory_wired: true))
    off = render("cpus=2\n", entry(disks: []))
    assert_match(/^memory\.wired=true$/, on)
    refute_match(/^memory\.wired=/, off)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/rtc_localtime|memory_wired|output_is_sorted/"`
Expected: FAIL (no `rtc.use_localtime` emitted; `test_output_is_sorted` missing the new line).

- [ ] **Step 3: Implement the generator**

In `lib/vmctl/config_renderer.rb`, append `tuning_keys` to the `generators` list (after `firmware_keys`):

```ruby
    def generators
      [method(:disk_keys), method(:net_keys), method(:iso_cd_keys),
       method(:seed_cd_keys), method(:hardware_keys), method(:graphics_keys),
       method(:firmware_keys), method(:tuning_keys)]
    end
```

Add the generator method (place it after `firmware_keys`):

```ruby
    # Guest tuning: RTC time base (always emitted; entry overrides the default)
    # and optional wired guest memory. NOTE: rtc uses a .nil? check, not ||, so an
    # explicit false is honored rather than falling back to the default.
    def tuning_keys(vm)
      e = vm.entry
      keys = {}
      lt = e.rtc_localtime.nil? ? @defaults.rtc_localtime : e.rtc_localtime
      keys['rtc.use_localtime'] = lt.to_s
      keys['memory.wired'] = 'true' if e.memory_wired
      keys
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n "/rtc_localtime|memory_wired|output_is_sorted/"`
Expected: PASS.

- [ ] **Step 5: Run the full suite and fix any remaining empty-rtc failures**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green. If any test fails with a rendered `rtc.use_localtime=` (empty value), it constructed a `Defaults` without `rtc_localtime` and reached a render path — add `rtc_localtime: true` to that `Defaults.new(...)`. (Expected candidates were handled in Step 1b; this catches any straggler in `test_supervisor.rb`/`test_provisioner.rb`/`test_cloudinit.rb` if one renders.)

- [ ] **Step 6: Commit**

```bash
git add lib/vmctl/config_renderer.rb test/test_config_renderer.rb test/test_vm.rb
git commit -m "feat(renderer): tuning_keys generator (rtc.use_localtime + memory.wired)"
```

---

### Task 3: CLI — create/set `--rtc-localtime` / `--memory-wired`

**Files:**
- Modify: `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/set.rb`, `lib/vmctl/cli.rb`
- Test: `test/test_create_command.rb`, `test/test_set_command.rb`

**Interfaces:**
- Consumes: `VMEntry#rtc_localtime`, `VMEntry#memory_wired` (Task 1).
- Produces: `create`/`set` flags that set the fields.

- [ ] **Step 1: Write the failing tests**

Add to `class TestCreateCommand` in `test/test_create_command.rb`:

```ruby
  def test_create_rtc_and_wired_flags
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--no-rtc-localtime', '--memory-wired']) }
    e = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_equal false, e.rtc_localtime
    assert_equal true, e.memory_wired
  end

  def test_create_without_tuning_flags_leaves_defaults
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    e = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_nil e.rtc_localtime          # inherit default at render
    assert_equal false, e.memory_wired
  end
```

Add to `class TestSetCommand` in `test/test_set_command.rb`:

```ruby
  def test_set_no_rtc_localtime
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--no-rtc-localtime']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').rtc_localtime
  end

  def test_set_rtc_localtime_true
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--rtc-localtime']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').rtc_localtime
  end

  def test_set_memory_wired_toggle
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--memory-wired']) }
    assert_equal true, VMCtl::Config.load(@inv).vms.fetch('pod34').memory_wired
    capture_stdout { cmd.call(['pod34', '--no-memory-wired']) }
    assert_equal false, VMCtl::Config.load(@inv).vms.fetch('pod34').memory_wired
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_create_command.rb -n "/rtc|wired|tuning/" && ruby -Ilib -Itest test/test_set_command.rb -n "/rtc|wired/"`
Expected: FAIL (unknown options / values not set).

- [ ] **Step 3: Implement `create` flags**

In `lib/vmctl/commands/create.rb`, add to `parse` (after the `--efi-vars` line):

```ruby
          p.on('--efi-vars')    { o[:efi_vars] = true }
          p.on('--rtc-localtime')    { o[:rtc_localtime] = true }
          p.on('--no-rtc-localtime') { o[:rtc_localtime] = false }
          p.on('--memory-wired')     { o[:memory_wired] = true }
          p.on('--start')       { o[:start] = true }
```

Add to the `VMEntry.new(...)` in `build_entry` (after `efi_vars:`):

```ruby
          efi_vars: !!opts[:efi_vars],
          rtc_localtime: opts[:rtc_localtime],
          memory_wired: !!opts[:memory_wired]
```

(`opts[:rtc_localtime]` is nil when neither flag is passed → inherit default.)

- [ ] **Step 4: Implement `set` flags**

In `lib/vmctl/commands/set.rb`, add to the `OptionParser` block (after the `--reset-efi-vars` line):

```ruby
          p.on('--reset-efi-vars') { opts[:reset_efi_vars] = true }
          p.on('--rtc-localtime')     { opts[:rtc_localtime] = true }
          p.on('--no-rtc-localtime')  { opts[:rtc_localtime] = false }
          p.on('--memory-wired')      { opts[:memory_wired] = true }
          p.on('--no-memory-wired')   { opts[:memory_wired] = false }
```

Add the apply clauses in `apply!` (after the `graphics` clause):

```ruby
        if opts.key?(:rtc_localtime)
          e.rtc_localtime = opts[:rtc_localtime]
          changed << "rtc_localtime=#{e.rtc_localtime}"
        end
        if opts.key?(:memory_wired)
          e.memory_wired = opts[:memory_wired]
          changed << "memory_wired=#{e.memory_wired}"
        end
```

- [ ] **Step 5: Update the CLI usage line**

In `lib/vmctl/cli.rb`, update the `set` usage line to list the new flags (add `/--rtc-localtime/--memory-wired` before `/--config`):

```ruby
        set <name> [opts]       Change VM fields (--autostart/--network[ none]/--mac/--mtu/--cpus/--memory/--graphics/--efi-vars/--reset-efi-vars/--rtc-localtime/--memory-wired/--config/--iso/--cloud-init/--var/--no-cloud-init).
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_create_command.rb -n "/rtc|wired|tuning/" && ruby -Ilib -Itest test/test_set_command.rb -n "/rtc|wired/"`
Expected: PASS (5 tests).

- [ ] **Step 7: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add lib/vmctl/commands/create.rb lib/vmctl/commands/set.rb lib/vmctl/cli.rb \
        test/test_create_command.rb test/test_set_command.rb
git commit -m "feat(cli): create/set --rtc-localtime and --memory-wired flags"
```

---

### Task 4: Docs — README + example inventory

**Files:**
- Modify: `README.md`, `examples/inventory.yml`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Document in the example inventory**

Read `examples/inventory.yml` first and match its aligned inline-comment style. Under `defaults:` (which currently ends with the `uefi_vars_template` line), add:

```yaml
  rtc_localtime: true          # RTC time base for all VMs: true=localtime (bhyve default), false=UTC. Set false for a UTC homelab.
```

Add commented examples to one existing VM entry:

```yaml
    # rtc_localtime: false    # this VM's clock uses UTC (Linux/BSD guests)
    # memory_wired: true      # pin (wire) this VM's guest memory; host won't swap it
```

Do not restructure the file or change unrelated lines.

- [ ] **Step 2: Document in the README**

Read `README.md` first (the bulleted generated/inventory-fields list). Add two bullets there:

- **RTC time base** (`rtc.use_localtime`) — `rtc_localtime` sets whether a VM's real-time clock uses localtime (bhyve default) or UTC. Per-VM, with a `defaults.rtc_localtime` fallback (default `true` = localtime). For a UTC homelab set `defaults.rtc_localtime: false` once; Linux/BSD guests generally want UTC.
- **Wired memory** (`memory.wired`) — `memory_wired: true` pins the VM's guest memory so the host won't swap it out (latency/perf-sensitive VMs). Per-VM opt-in; default off.

Match the README's existing heading level and prose style; do not restructure existing sections.

- [ ] **Step 3: Run the full suite (docs shouldn't affect it; confirm)**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add README.md examples/inventory.yml
git commit -m "docs: document rtc_localtime + memory_wired tuning fields"
```

---

## Self-Review

**Spec coverage:**
- `rtc_localtime` on `VMEntry` (nil when unset) + `Defaults`/`DEFAULTS` (default true) → Task 1. ✓
- `memory_wired` on `VMEntry` (false when absent) → Task 1. ✓
- `parse_vm` preserves explicit `false` for rtc (key? check, not fetch-default) → Task 1. ✓
- `vm_to_h` emits rtc when non-nil (true OR false), memory_wired when true → Task 1. ✓
- `tuning_keys` generator: rtc always-emit with `.nil?` (not `||`), memory.wired only-when-true, appended last → Task 2. ✓
- Exact-output ripple (`test_output_is_sorted`) + test-`Defaults` updates → Task 2 (Steps 1a–1c, 5). ✓
- Explicit-false-is-honored test (guards the `.nil?` vs `||` bug) → Task 2 (`test_rtc_localtime_entry_false_is_honored`). ✓
- CLI create/set flags + usage → Task 3. ✓
- README + example inventory + homelab UTC tip → Task 4. ✓
- No migration; both booleans, no validation → constraints + Task 1 (no error paths). ✓

**Placeholder scan:** No TBD/TODO. Task 2 Step 5's "fix any straggler" is a concrete, bounded mechanical follow-through with an exact signal (a rendered `rtc.use_localtime=` empty value) and fix (add `rtc_localtime: true`), not a placeholder. Task 4 says "read the file and match style" because the README/example structure isn't reproduced, but the required content is fully enumerated.

**Type consistency:** `rtc_localtime` is boolean-or-nil everywhere (`entry.rtc_localtime`, `opts[:rtc_localtime]`, `body.key?('rtc_localtime') ? ... : nil`, resolved via `.nil?`); `memory_wired` is boolean (`body.fetch('memory_wired', false)`, `!!opts[:memory_wired]`, emitted only when true). `Defaults#rtc_localtime` is boolean (default true). `tuning_keys` reads `@defaults.rtc_localtime` (Task 1 provides it) and `e.rtc_localtime`/`e.memory_wired`. Generator appended after `firmware_keys`, consistent with the established order. CLI `set` uses `opts.key?` gating (matches graphics/efi_vars), so `--no-rtc-localtime` (false) applies rather than skips.
