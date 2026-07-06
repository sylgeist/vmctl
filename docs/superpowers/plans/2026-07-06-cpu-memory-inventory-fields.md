# CPU/Memory as Inventory Fields Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CPU and memory per-VM inventory fields (`cpus:` / `memory:`) generated into the bhyve config, with `defaults.cpus`=1 / `defaults.memory`=1G, `create`/`set --cpus`/`--memory`, and templates no longer declaring them.

**Architecture:** A `hardware_keys` generator emits `cpus` + `memory.size` from the entry (falling back to `@defaults`); generated keys win over the flavor and `options:`. `memory` is a `Sizes`-format string (`1G`/`512M`).

**Tech Stack:** Ruby stdlib, minitest, `FakeExecutor`.

## Global Constraints

- Ruby 4.0 (CI: `ruby -Ilib -Itest test/run_all.rb`). No new gems.
- Source files keep `# frozen_string_literal: true` + `# lib/vmctl/<path>` headers.
- Tests are minitest, `FakeExecutor` at the shell-out boundary.
- `memory` uses `Sizes.parse` format: 1024-based, single-letter suffix `K`/`M`/`G`/`T` (e.g. `1G`, `512M`). `1GB` is invalid. Renders to `memory.size=<value>`. `cpus` is a positive integer → `cpus=<n>`.
- Defaults live in `Config::DEFAULTS` (`'cpus' => 1`, `'memory' => '1G'`); per-VM values are nil when unset (byte-stable `vm_to_h`); the renderer resolves the default via `@defaults`.
- User-facing errors: `VMCtl::Commands::CommandError`; load-time schema errors: `VMCtl::ConfigError`.
- Git commits end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Branch `feat/cpu-memory-fields`.

---

## Task 1: `cpus`/`memory` schema + defaults

**Files:**
- Modify: `lib/vmctl/config.rb`
- Test: `test/test_config.rb`

**Interfaces:**
- Produces: `Defaults#cpus` (Integer, default 1) / `Defaults#memory` (String, default '1G'); `VMEntry#cpus` (Integer|nil) / `VMEntry#memory` (String|nil). `vm_to_h` emits each only when non-nil.

- [ ] **Step 1: Write the failing tests** — add to `test/test_config.rb`:

```ruby
  def test_defaults_cpus_and_memory_fallback
    f = write_inventory("vms: {}\n")
    cfg = VMCtl::Config.load(f.path)
    assert_equal 1, cfg.defaults.cpus
    assert_equal '1G', cfg.defaults.memory
    f.close
  end

  def test_defaults_cpus_and_memory_override
    inv = "defaults: { cpus: 4, memory: 8G }\nvms: {}\n"
    cfg = VMCtl::Config.load(write_inventory(inv).path)
    assert_equal 4, cfg.defaults.cpus
    assert_equal '8G', cfg.defaults.memory
  end

  def test_vm_cpus_and_memory_parse_and_roundtrip
    inv = <<~YAML
      defaults: { config_dir: /c, vm_root: /v, zpool: tank, link_base: 10 }
      vms:
        pod34: { network: n, link: 10, disks: [], cpus: 2, memory: 4G }
    YAML
    cfg = VMCtl::Config.load(write_inventory(inv).path)
    vm = cfg.vms.fetch('pod34')
    assert_equal 2, vm.cpus
    assert_equal '4G', vm.memory
    out = Tempfile.new(['out', '.yml']); cfg.save(out.path)
    r = VMCtl::Config.load(out.path).vms.fetch('pod34')
    assert_equal 2, r.cpus
    assert_equal '4G', r.memory
    out.close
  end

  def test_vm_cpus_and_memory_absent_not_emitted
    f = write_inventory(VALID_INVENTORY)
    cfg = VMCtl::Config.load(f.path)
    assert_nil cfg.vms.fetch('pod34').cpus
    out = Tempfile.new(['out', '.yml']); cfg.save(out.path)
    body = File.read(out.path)
    refute_match(/cpus:/, body)
    refute_match(/memory:/, body)
    f.close; out.close
  end

  def test_bad_cpus_raises
    inv = "vms:\n  p: { network: n, link: 10, disks: [], cpus: 0 }\n"
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(write_inventory(inv).path) }
    inv2 = "vms:\n  p: { network: n, link: 10, disks: [], cpus: nope }\n"
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(write_inventory(inv2).path) }
  end

  def test_bad_memory_raises
    inv = "vms:\n  p: { network: n, link: 10, disks: [], memory: 1GB }\n"
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(write_inventory(inv).path) }
  end
```

- [ ] **Step 2: Run — FAIL**

Run: `ruby -Ilib -Itest test/test_config.rb -n test_vm_cpus_and_memory_parse_and_roundtrip`
Expected: FAIL (`undefined method 'cpus'`).

- [ ] **Step 3: Implement** — in `lib/vmctl/config.rb`:

Add `require_relative 'sizes'` near the top (after `require 'tempfile'`).

Extend the structs:
```ruby
  Defaults = Struct.new(
    :config_dir, :vm_root, :zpool, :template, :link_base, :run_dir, :log_dir,
    :image_dir, :root_size, :root_from, :cpus, :memory,
    keyword_init: true
  )
  VMEntry = Struct.new(
    :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
    :options, :mtu, :networks, :cpus, :memory,
    keyword_init: true
  )
```

Add to `Config::DEFAULTS` (after `'root_from' => nil`):
```ruby
    'cpus'   => 1,
    'memory' => '1G'
```

In `parse_defaults`, add (after `root_from:`):
```ruby
        cpus:       parse_cpus(merged['cpus']),
        memory:     parse_memory(merged['memory'])
```

In `parse_vm`, add (after `networks:`):
```ruby
        cpus:       parse_cpus(body['cpus']),
        memory:     parse_memory(body['memory'])
```

Add the private parsers near `parse_options`:
```ruby
    def parse_cpus(v)
      return nil if v.nil?
      n = Integer(v, exception: false)
      raise ConfigError, "'cpus' must be a positive integer, got: #{v.inspect}" if n.nil? || n <= 0
      n
    end

    def parse_memory(v)
      return nil if v.nil?
      Sizes.parse(v)   # validates format; raises ArgumentError on bad input
      v.to_s
    rescue ArgumentError
      raise ConfigError, "'memory' must be a size like 1G/512M, got: #{v.inspect}"
    end
```

In `vm_to_h`, add (after the `options` line):
```ruby
      h['cpus'] = vm.cpus unless vm.cpus.nil?
      h['memory'] = vm.memory unless vm.memory.nil?
```

- [ ] **Step 4: Run — PASS**

Run: `ruby -Ilib -Itest test/test_config.rb && ruby -Ilib -Itest test/run_all.rb`
Expected: PASS (rendering is unchanged in this task, so no other suite breakage).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "$(printf 'feat(config): cpus/memory VM fields + defaults (1/1G)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 2: `hardware_keys` generator (+ update output-assertion tests)

**Files:**
- Modify: `lib/vmctl/config_renderer.rb`
- Test: `test/test_config_renderer.rb`, `test/test_vm.rb`, `test/test_dump_command.rb`, `test/test_commands.rb`

**Interfaces:**
- Produces: `ConfigRenderer` always emits `cpus=<entry.cpus || defaults.cpus>` and `memory.size=<entry.memory || defaults.memory>` (generated → overrides flavor + `options:`).

**IMPORTANT — this changes rendered output.** Because `cpus`/`memory.size` are now always generated and win, several existing tests that asserted these from a flavor/options must be updated (enumerated in Step 1). Any test building a `Defaults` directly and then rendering must include `cpus:`/`memory:` (else the fallback yields an empty `cpus=`).

- [ ] **Step 1: Update helpers + write/adjust tests**

`test/test_config_renderer.rb`:
- Extend the `defaults(dir)` helper to pass `cpus: 1, memory: '1G'` to `Defaults.new`.
- Extend the `entry` helper with `cpus: nil, memory: nil` kwargs passed to `VMEntry.new`.
- Update `test_output_is_sorted`: it now also emits `cpus`/`memory.size`. Change the expected to:
  ```ruby
  assert_equal %w[alpha=2 cpus=1 memory.size=1G zeta=1], out.split("\n")
  ```
- Update `test_options_override_base` to use a **non-hardware** key (cpus is now generated and wins over options, so it's no longer a valid "options beat flavor" example):
  ```ruby
  def test_options_override_base
    out = render("custom=2\n", entry(disks: [], options: { 'custom' => 4 }))
    assert_match(/^custom=4$/, out)
    refute_match(/^custom=2$/, out)
  end
  ```
- Add new tests:
  ```ruby
  def test_hardware_from_entry
    out = render("cpus=99\nmemory.size=99G\n", entry(disks: [], cpus: 2, memory: '4G'))
    assert_match(/^cpus=2$/, out)
    assert_match(/^memory\.size=4G$/, out)
    refute_match(/^cpus=99$/, out)          # generated overrides the flavor
    refute_match(/^memory\.size=99G$/, out)
  end

  def test_hardware_falls_back_to_defaults
    out = render("cpus=99\n", entry(disks: []))   # entry cpus/memory nil
    assert_match(/^cpus=1$/, out)                 # defaults(dir) -> cpus 1
    assert_match(/^memory\.size=1G$/, out)
  end

  def test_hardware_overrides_options
    out = render("cpus=2\n", entry(disks: [], cpus: 8, options: { 'cpus' => 5 }))
    assert_match(/^cpus=8$/, out)                 # generated beats options
    refute_match(/^cpus=5$/, out)
  end
  ```

`test/test_vm.rb`:
- Extend the `defaults` helper to include `cpus: 1, memory: '1G'`, and add the same to the inline `Defaults.new` inside `test_render_and_write_config`.
- In `test_render_and_write_config`, the flavor's `cpus=2` is now overridden by the generated default; change `assert_match(/^cpus=2$/, text)` to `assert_match(/^cpus=1$/, text)`.

`test/test_dump_command.rb`:
- Give the dump VM an explicit `memory: 4G` in its inventory so the rendered `memory.size=4G` assertion stays meaningful (the flavor's `memory.size=4G` is otherwise overridden by the `1G` default). I.e. add `memory: 4G` to the `pod34` entry in `load_config`'s inventory heredoc; keep `assert_match(/^memory\.size=4G$/, out)`.

`test/test_commands.rb`:
- In `TestStartCommand#test_start_writes_ephemeral_config`, the shared flavor's `cpus=2` is now overridden by the generated default (`cpus=1`). Change `assert_match(/^cpus=2$/, written)` to `assert_match(/^cpus=1$/, written)`. (The disk-path assertion in that test is unaffected.)

- [ ] **Step 2: Run — FAIL**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb -n test_hardware_from_entry`
Expected: FAIL (no `cpus`/`memory.size` generated yet — flavor's `99` survives).

- [ ] **Step 3: Implement** — in `lib/vmctl/config_renderer.rb`, append `hardware_keys` to the list and add the method:

```ruby
    def generators
      [method(:disk_keys), method(:net_keys), method(:iso_cd_keys),
       method(:seed_cd_keys), method(:hardware_keys)]
    end

    # CPU/memory from the inventory (entry, falling back to defaults).
    def hardware_keys(vm)
      {
        'cpus'        => (vm.entry.cpus   || @defaults.cpus).to_s,
        'memory.size' => (vm.entry.memory || @defaults.memory).to_s
      }
    end
```

- [ ] **Step 4: Run — PASS**

Run: `ruby -Ilib -Itest test/test_config_renderer.rb && ruby -Ilib -Itest test/test_vm.rb && ruby -Ilib -Itest test/test_dump_command.rb && ruby -Ilib -Itest test/test_commands.rb && ruby -Ilib -Itest test/run_all.rb`
Expected: PASS. If any *other* file has an exact-output assertion on rendered `cpus`/`memory.size`, report it (the four above are the expected ones).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config_renderer.rb test/test_config_renderer.rb test/test_vm.rb test/test_dump_command.rb test/test_commands.rb
git commit -m "$(printf 'feat: generate cpus/memory.size from inventory (entry or defaults)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 3: `create --cpus --memory` (+ shared validators on Base)

**Files:**
- Modify: `lib/vmctl/commands/base.rb`, `lib/vmctl/commands/create.rb`
- Test: `test/test_create_command.rb`

**Interfaces:**
- Produces (on `Commands::Base`, protected): `positive_int!(v, flag)` → Integer or `CommandError`; `valid_size!(v, flag)` → the size String or `CommandError`. Reused by Task 4. `create` sets `entry.cpus`/`entry.memory` from `--cpus`/`--memory`.

- [ ] **Step 1: Write the failing tests** — add to `test/test_create_command.rb`:

```ruby
  def test_create_cpus_and_memory
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--cpus', '4', '--memory', '8G']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_equal 4, entry.cpus
    assert_equal '8G', entry.memory
  end

  def test_create_defaults_cpus_memory_when_omitted
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50']) }
    entry = VMCtl::Config.load(@inv).vms.fetch('pod35')
    assert_nil entry.cpus       # nil -> renderer applies defaults.cpus
    assert_nil entry.memory
  end

  def test_create_rejects_bad_cpus
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--cpus', '0'])
    end
  end

  def test_create_rejects_bad_memory
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--memory', '1GB'])
    end
  end
```

- [ ] **Step 2: Run — FAIL**

Run: `ruby -Ilib -Itest test/test_create_command.rb -n test_create_cpus_and_memory`
Expected: FAIL (`--cpus` unknown / cpus nil).

- [ ] **Step 3: Implement**

In `lib/vmctl/commands/base.rb`, add `require_relative '../sizes'` at the top, and add two protected helpers (near `note_next_boot`):
```ruby
      def positive_int!(v, flag)
        n = Integer(v, exception: false)
        raise CommandError, "invalid #{flag} #{v.inspect}" if n.nil? || n <= 0
        n
      end

      def valid_size!(v, flag)
        Sizes.parse(v)
        v
      rescue ArgumentError
        raise CommandError, "invalid #{flag} #{v.inspect}"
      end
```

In `lib/vmctl/commands/create.rb`, add to the `parse` OptionParser block:
```ruby
          p.on('--cpus N')     { |v| o[:cpus] = v }
          p.on('--memory SIZE') { |v| o[:memory] = v }
```
and in `build_entry`, add to the `VMEntry.new(...)` keywords:
```ruby
          cpus: opts[:cpus] && positive_int!(opts[:cpus], '--cpus'),
          memory: opts[:memory] && valid_size!(opts[:memory], '--memory')
```

- [ ] **Step 4: Run — PASS**

Run: `ruby -Ilib -Itest test/test_create_command.rb && ruby -Ilib -Itest test/run_all.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/base.rb lib/vmctl/commands/create.rb test/test_create_command.rb
git commit -m "$(printf 'feat(create): --cpus/--memory (shared positive_int!/valid_size! on Base)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 4: `set --cpus --memory`

**Files:**
- Modify: `lib/vmctl/commands/set.rb`
- Test: `test/test_set_command.rb`

**Interfaces:**
- Consumes: `Commands::Base#positive_int!` / `valid_size!` (Task 3).
- Produces: `set --cpus N` / `--memory SIZE` edit `entry.cpus`/`entry.memory`.

- [ ] **Step 1: Write the failing tests** — add to `test/test_set_command.rb`:

```ruby
  def test_set_cpus
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--cpus', '4']) }
    assert_equal 4, VMCtl::Config.load(@inv).vms.fetch('pod34').cpus
  end

  def test_set_memory
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--memory', '2G']) }
    assert_equal '2G', VMCtl::Config.load(@inv).vms.fetch('pod34').memory
  end

  def test_set_rejects_bad_cpus
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--cpus', 'x']) }
  end

  def test_set_rejects_bad_memory
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--memory', '1GB']) }
  end
```

- [ ] **Step 2: Run — FAIL**

Run: `ruby -Ilib -Itest test/test_set_command.rb -n test_set_cpus`
Expected: FAIL (`--cpus` unknown).

- [ ] **Step 3: Implement** — in `lib/vmctl/commands/set.rb`:

Add to the parser block:
```ruby
          p.on('--cpus N')      { |v| opts[:cpus] = v }
          p.on('--memory SIZE') { |v| opts[:memory] = v }
```
Add to `apply!` (after the mtu branch):
```ruby
        if opts.key?(:cpus)
          e.cpus = positive_int!(opts[:cpus], '--cpus')
          changed << "cpus=#{e.cpus}"
        end
        if opts.key?(:memory)
          e.memory = valid_size!(opts[:memory], '--memory')
          changed << "memory=#{e.memory}"
        end
```

- [ ] **Step 4: Run — PASS**

Run: `ruby -Ilib -Itest test/test_set_command.rb && ruby -Ilib -Itest test/run_all.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/set.rb test/test_set_command.rb
git commit -m "$(printf 'feat(set): --cpus/--memory\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 5: migrate example flavor + inventory + README

**Files:**
- Modify: `examples/pod.conf`, `examples/inventory.yml`, `README.md`
- Test: none (run full suite to confirm nothing load-bearing changed).

- [ ] **Step 1: Trim `examples/pod.conf`** — delete the `cpus=2` and `memory.size=4G` lines. Update the header: templates declare OS-core only (bootrom, hostbridge, rng, lpc/console, acpi flags) — CPU/memory (like disks/NICs/CDs) come from the inventory.

- [ ] **Step 2: Update `examples/inventory.yml`** — add under `defaults:` (with a brief comment):
```yaml
  cpus: 1         # default vCPU count; per-VM override with `cpus:`
  memory: 1G      # default memory (Sizes format: 1G/512M); per-VM override with `memory:`
```
Optionally show a per-VM `cpus:`/`memory:` on one VM.

- [ ] **Step 3: Update `README.md`** — note that CPU and memory are inventory fields (`cpus:` / `memory:`, `memory` in `1G`/`512M` size format) with a `defaults` fallback (1 / 1G), generated into the config, and no longer declared in templates; `create`/`set` accept `--cpus`/`--memory`.

- [ ] **Step 4: Run** `ruby -Ilib -Itest test/run_all.rb` → PASS.

- [ ] **Step 5: Commit**

```bash
git add examples/pod.conf examples/inventory.yml README.md
git commit -m "$(printf 'docs: cpus/memory are inventory fields; drop them from templates\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] Full suite: `ruby -Ilib -Itest test/run_all.rb` → all PASS.
- [ ] `grep -rn 'cpus\|memory' examples/*.conf` → no `cpus=`/`memory.size=` declaration lines remain.
- [ ] `ruby -Ilib bin/vmctl help` renders; `git log --oneline` shows the 5 task commits on `feat/cpu-memory-fields`.

## Notes for the implementer

- Default resolution happens at **render** (`hardware_keys` uses `@defaults`), not at parse — so `entry.cpus`/`memory` stay nil when unset and `vm_to_h` stays byte-stable for existing inventories.
- Generated `cpus`/`memory.size` win over both the flavor and `options:` (Task 2 tests this). Operators who set these via `options:` should move to the first-class fields.
- Only `config.save` is gated on `unless executor.dry_run?` in create/set; validation happens before mutation.
