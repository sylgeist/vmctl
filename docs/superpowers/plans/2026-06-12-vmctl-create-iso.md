# `create --iso` Installer ISO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `vmctl create --iso FILE` attach an installer ISO to a new VM via a `%(iso)` bhyve config variable, persisted as `iso:` in the inventory.

**Architecture:** Mirrors how `network`/`link`/`mac` flow today: the inventory entry stores the absolute ISO path, `VM#bhyve_argv` appends `-o iso=<path>`, and an installer-capable template declares the AHCI-CD device itself, referencing `%(iso)` for the media path. Cross-validation (VM has `iso:` ⟺ template references `%(iso)`) runs at both `create` and `start`.

**Tech Stack:** Ruby 3 stdlib only, Minitest (`ruby -Ilib -Itest test/run_all.rb`).

**Spec:** `docs/superpowers/specs/2026-06-12-vmctl-create-iso-design.md`

**Conventions to follow:**
- Tests use the existing `FakeExecutor` from `test/test_helper.rb`; never shell out for real.
- Run a single test file with `ruby -Ilib -Itest test/test_vm.rb`; full suite with `ruby -Ilib -Itest test/run_all.rb`. Suite is currently green at 112 runs.
- Git commits in this repo require the sandbox disabled (sandbox denies `.git` writes).

---

### Task 1: `iso` field on `VMEntry` (parse + serialize)

**Files:**
- Modify: `lib/vmctl/config.rb` (VMEntry struct ~line 14, `parse_vm` ~line 107, `vm_to_h` ~line 135)
- Test: `test/test_config.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config.rb` inside `class TestConfig`, after `test_save_round_trips`:

```ruby
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
```

(The appended `iso:` line uses 4-space indentation to sit at the same level as `pod34:`'s other keys in `VALID_INVENTORY`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_config.rb`
Expected: 2 failures/errors — `NoMethodError: undefined method 'iso'` for VMEntry.

- [ ] **Step 3: Implement**

In `lib/vmctl/config.rb`:

VMEntry struct — add `:iso` at the end (keyword_init means existing callers are unaffected):

```ruby
VMEntry = Struct.new(
  :name, :config, :network, :link, :mac, :autostart, :disks, :cloud_init, :iso,
  keyword_init: true
)
```

`parse_vm` — add `iso:` after `cloud_init:`:

```ruby
cloud_init: body['cloud_init'],
iso:        body['iso']
```

`vm_to_h` — after the `cloud_init` line:

```ruby
h['cloud_init'] = vm.cloud_init if vm.cloud_init
h['iso'] = vm.iso if vm.iso
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_config.rb`
Expected: PASS (all tests in file).

- [ ] **Step 5: Run full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: 114 runs, 0 failures, 0 errors.

- [ ] **Step 6: Commit** (sandbox disabled for git)

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "feat: add iso field to inventory VM entries

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `VM#bhyve_argv` emits `-o iso=`; `VM#template_wants_iso?`

**Files:**
- Modify: `lib/vmctl/vm.rb` (`bhyve_argv` ~line 18; new method after `template_path` ~line 41)
- Test: `test/test_vm.rb`

- [ ] **Step 1: Write the failing tests**

In `test/test_vm.rb`, extend the two fixture helpers to accept overrides:

```ruby
def defaults(config_dir: '/bhyve/configs')
  VMCtl::Defaults.new(
    config_dir: config_dir, vm_root: '/bhyve', zpool: 'tank/bhyve',
    template: 'pod.conf', link_base: 10,
    run_dir: '/var/run/vmctl', log_dir: '/var/log/vmctl'
  )
end

def entry(mac: nil, iso: nil, config: 'pod.conf')
  VMCtl::VMEntry.new(
    name: 'pod34', config: config, network: 'labs_vlan50', link: 10,
    mac: mac, autostart: true,
    disks: [VMCtl::Disk.new(file: 'pod34-root.raw', size: '20G', from: nil)],
    cloud_init: nil, iso: iso
  )
end
```

Add `require 'tmpdir'` to the top of the file, then the tests:

```ruby
def test_bhyve_argv_includes_iso_when_set
  vm = VMCtl::VM.new(entry(iso: '/bhyve/isos/install.iso'), defaults)
  assert_includes vm.bhyve_argv, 'iso=/bhyve/isos/install.iso'
end

def test_bhyve_argv_omits_iso_when_nil
  vm = VMCtl::VM.new(entry, defaults)
  refute(vm.bhyve_argv.any? { |a| a.start_with?('iso=') })
end

def test_dump_command_includes_iso_when_set
  vm = VMCtl::VM.new(entry(iso: '/bhyve/isos/install.iso'), defaults)
  assert_includes vm.dump_command, '-o iso=/bhyve/isos/install.iso'
end

def test_template_wants_iso_detects_reference
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'inst.conf'), "pci.0.5.0.port.0.path=%(iso)\n")
    vm = VMCtl::VM.new(entry(config: 'inst.conf'), defaults(config_dir: dir))
    assert vm.template_wants_iso?
  end
end

def test_template_wants_iso_false_when_absent
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'plain.conf'), "cpus=2\n")
    vm = VMCtl::VM.new(entry(config: 'plain.conf'), defaults(config_dir: dir))
    refute vm.template_wants_iso?
  end
end

def test_template_wants_iso_ignores_commented_lines
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'c.conf'), "cpus=2\n#pci.0.5.0.port.0.path=%(iso)\n")
    vm = VMCtl::VM.new(entry(config: 'c.conf'), defaults(config_dir: dir))
    refute vm.template_wants_iso?
  end
end

def test_template_wants_iso_false_when_template_missing
  vm = VMCtl::VM.new(entry(config: 'nope.conf'), defaults)
  refute vm.template_wants_iso?
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_vm.rb`
Expected: `test_bhyve_argv_includes_iso_when_set`, `test_dump_command_includes_iso_when_set` fail (assertion); `template_wants_iso` tests error with `NoMethodError`. Pre-existing tests still pass.

- [ ] **Step 3: Implement**

In `lib/vmctl/vm.rb`, `bhyve_argv` — add the iso line after the mac line:

```ruby
argv += ['-o', "mac=#{@entry.mac}"] if @entry.mac
argv += ['-o', "iso=#{@entry.iso}"] if @entry.iso
```

After `template_path`, add:

```ruby
# True when the template consumes the %(iso) config variable on an active
# (non-comment) line. False if the template file is missing — template
# existence is validated elsewhere.
def template_wants_iso?
  return false unless File.exist?(template_path)
  File.foreach(template_path).any? do |line|
    line.sub(/#.*/, '').include?('%(iso)')
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_vm.rb`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: 121 runs, 0 failures, 0 errors.

- [ ] **Step 6: Commit** (sandbox disabled for git)

```bash
git add lib/vmctl/vm.rb test/test_vm.rb
git commit -m "feat: pass -o iso= to bhyve; detect %(iso) in templates

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `create --iso` with validation

**Files:**
- Modify: `lib/vmctl/commands/base.rb` (new protected helper)
- Modify: `lib/vmctl/commands/create.rb` (`parse` ~line 39, `build_entry` ~line 57, `validate!` ~line 95)
- Test: `test/test_create_command.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/test_create_command.rb` inside `class TestCreateCommand`:

```ruby
def write_installer_template
  File.write(File.join(@config_dir, 'installer.conf'),
             "cpus=2\npci.0.5.0.port.0.path=%(iso)\n")
end

def write_iso
  iso = File.join(@dir, 'install.iso')
  File.write(iso, 'iso')
  iso
end

def test_create_iso_records_absolute_path
  write_installer_template
  iso = write_iso
  exec = bridge_ok
  cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
  capture_stdout do
    cmd.call(['pod36', '--network', 'labs_vlan50',
              '--config', 'installer.conf', '--iso', iso])
  end
  entry = VMCtl::Config.load(@inv).vms.fetch('pod36')
  assert_equal iso, entry.iso
end

def test_create_iso_expands_relative_path
  write_installer_template
  write_iso
  exec = bridge_ok
  cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
  Dir.chdir(@dir) do
    capture_stdout do
      cmd.call(['pod36', '--network', 'labs_vlan50',
                '--config', 'installer.conf', '--iso', 'install.iso'])
    end
  end
  entry = VMCtl::Config.load(@inv).vms.fetch('pod36')
  assert_equal File.join(@dir, 'install.iso'), entry.iso
end

def test_create_rejects_missing_iso_file
  write_installer_template
  cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
  err = assert_raises(VMCtl::Commands::CommandError) do
    cmd.call(['pod36', '--network', 'labs_vlan50',
              '--config', 'installer.conf', '--iso', '/nonexistent.iso'])
  end
  assert_match(/iso not found/, err.message)
end

def test_create_rejects_iso_when_template_lacks_reference
  iso = write_iso
  cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
  err = assert_raises(VMCtl::Commands::CommandError) do
    # default template pod.conf has no %(iso)
    cmd.call(['pod36', '--network', 'labs_vlan50', '--iso', iso])
  end
  assert_match(/does not reference/, err.message)
end

def test_create_rejects_installer_template_without_iso
  write_installer_template
  cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
  err = assert_raises(VMCtl::Commands::CommandError) do
    cmd.call(['pod36', '--network', 'labs_vlan50', '--config', 'installer.conf'])
  end
  assert_match(/references %\(iso\)/, err.message)
end
```

Note: `test_create_iso_expands_relative_path` asserts on the path before symlink resolution; if it flakes on macOS (`/var` vs `/private/var` in `Dir.mktmpdir`), compare `File.realpath`s instead.

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_create_command.rb`
Expected: the 5 new tests fail — `OptionParser::InvalidOption: invalid option: --iso` surfacing or assertion failures. Pre-existing tests pass.

- [ ] **Step 3: Implement**

In `lib/vmctl/commands/base.rb`, add to the `protected` section of `Base` (after `targets`):

```ruby
# A VM with iso: needs a template that consumes %(iso), and vice versa —
# otherwise bhyve sees an undefined config variable or an empty CD path.
def validate_iso_pairing!(vm)
  if vm.entry.iso && !vm.template_wants_iso?
    raise CommandError,
          "template #{vm.entry.config} does not reference %(iso) (use an installer template)"
  end
  if !vm.entry.iso && vm.template_wants_iso?
    raise CommandError,
          "template #{vm.entry.config} references %(iso) but VM #{vm.name} has no iso"
  end
end
```

In `lib/vmctl/commands/create.rb`:

`parse` — add after the `--cloud-init` line:

```ruby
p.on('--iso FILE') { |v| o[:iso] = v }
```

`build_entry` — add to the `VMEntry.new` call after `cloud_init: nil` (absolute path because bhyve runs detached from an unrelated cwd):

```ruby
cloud_init: nil,
iso: opts[:iso] && File.expand_path(opts[:iso])
```

`validate!` — after the `template not found` check (so the pairing check reads a template known to exist) and before the disk loop:

```ruby
if entry.iso && !File.exist?(entry.iso)
  raise CommandError, "iso not found: #{entry.iso}"
end
validate_iso_pairing!(vm)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_create_command.rb`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: 126 runs, 0 failures, 0 errors.

- [ ] **Step 6: Commit** (sandbox disabled for git)

```bash
git add lib/vmctl/commands/base.rb lib/vmctl/commands/create.rb test/test_create_command.rb
git commit -m "feat: create --iso attaches an installer ISO via %(iso)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `start` re-validates the iso/template pairing

The inventory is hand-edited, so the pair can drift after creation (e.g. the
`iso:` line removed but the installer template kept, or vice versa).

**Files:**
- Modify: `lib/vmctl/commands/start.rb` (`start_one` ~line 25)
- Test: `test/test_commands.rb` (inside `class TestStartCommand`)

- [ ] **Step 1: Write the failing tests**

`test/test_commands.rb` already requires `tempfile`; add `require 'tmpdir'` to the requires at the top. Then add inside `class TestStartCommand`:

```ruby
def config_for_iso(template_body:, iso:)
  dir = Dir.mktmpdir
  File.write(File.join(dir, 'inst.conf'), template_body)
  inv = <<~YAML
    defaults:
      config_dir: #{dir}
      vm_root: /bhyve
      zpool: tank/bhyve
      link_base: 10
      run_dir: /tmp/vmctl-test-run
      log_dir: /tmp/vmctl-test-log
    vms:
      pod36:
        config: inst.conf
        network: labs_vlan50
        link: 12
        disks: [{ file: pod36-root.raw, size: 20G }]
  YAML
  inv += "    iso: #{iso}\n" if iso
  f = Tempfile.new(['inv', '.yml'])
  f.write(inv)
  f.flush
  VMCtl::Config.load(f.path)
end

def never_start_factory
  ->(_vm, **) { flunk 'supervisor must not start when iso validation fails' }
end

def test_start_rejects_iso_when_template_lacks_reference
  cfg = config_for_iso(template_body: "cpus=2\n", iso: '/bhyve/isos/x.iso')
  exec = FakeExecutor.new(probes: { '/dev/vmm/pod36' => false,
                                    'ngctl info labs_vlan50:' => true })
  cmd = VMCtl::Commands::Start.new(config: cfg, executor: exec,
                                   supervisor_factory: never_start_factory)
  err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod36']) }
  assert_match(/does not reference/, err.message)
end

def test_start_rejects_installer_template_without_iso
  cfg = config_for_iso(template_body: "pci.0.5.0.port.0.path=%(iso)\n", iso: nil)
  exec = FakeExecutor.new(probes: { '/dev/vmm/pod36' => false,
                                    'ngctl info labs_vlan50:' => true })
  cmd = VMCtl::Commands::Start.new(config: cfg, executor: exec,
                                   supervisor_factory: never_start_factory)
  err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod36']) }
  assert_match(/references %\(iso\)/, err.message)
end
```

(The appended `iso:` line uses 4-space indentation to match the other `pod36:` keys. The `/dev/vmm/pod36 => false` probe is required: `FakeExecutor#success?` defaults to true, which would trip the "already running" check first.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/test_commands.rb`
Expected: the 2 new tests fail — no CommandError raised (the flunk in the factory fires, or the supervisor call errors). Pre-existing tests pass. Note: existing start tests point `config_dir` at `/bhyve/configs` (missing on the test machine); `template_wants_iso?` returns false for missing templates, so they stay green.

- [ ] **Step 3: Implement**

In `lib/vmctl/commands/start.rb`, `start_one` — add after the "already running" check:

```ruby
raise CommandError, "#{vm.name} already running" if vm.running?(executor)
validate_iso_pairing!(vm)
@netgraph.ensure_bridge!(vm.entry.network)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/test_commands.rb`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: 128 runs, 0 failures, 0 errors.

- [ ] **Step 6: Commit** (sandbox disabled for git)

```bash
git add lib/vmctl/commands/start.rb test/test_commands.rb
git commit -m "feat: start validates iso/template %(iso) pairing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: example installer template + README

No code; no tests. Documentation must match the behavior shipped in Tasks 1–4.

**Files:**
- Create: `examples/pod-installer.conf`
- Modify: `README.md` (examples list ~line 54, Provisioning section ~line 96)

- [ ] **Step 1: Create `examples/pod-installer.conf`**

```
# Example installer template: a single root disk plus an AHCI-CD device that
# boots an installer ISO supplied per-VM.
#
# vmctl keeps templates opaque — it does NOT add the CD device for you. A VM
# created with `vmctl create <name> --iso /path/to/installer.iso` must use a
# template like this one that consumes the %(iso) config variable; vmctl
# supplies it at start as `-o iso=/path/to/installer.iso`.
#
# The iso: entry persists in the inventory and is attached read-only on every
# start. With UEFI this is harmless after installation (the installed disk
# boots first); remove the VM's iso: line from the inventory to detach.

acpi_tables=true
destroy_on_poweroff=true
x86.vmexit_on_hlt=true
x86.vmexit_on_pause=true

cpus=2
memory.size=4G

pci.0.0.0.device=hostbridge

pci.0.3.0.device=nvme
pci.0.3.0.path=/bhyve/%(name)/%(name)-root.raw

# Installer CD: media path supplied per-VM via `-o iso=...`.
pci.0.5.0.device=ahci
pci.0.5.0.port.0.type=cd
pci.0.5.0.port.0.ro=true
pci.0.5.0.port.0.path=%(iso)

pci.0.4.0.device=virtio-net
pci.0.4.0.backend=netgraph
pci.0.4.0.path=%(network):
pci.0.4.0.peerhook=link%(link)
pci.0.4.0.socket=bhyve_%(name)
pci.0.4.0.mtu=9000
#pci.0.4.0.mac=%(mac)

pci.0.20.0.device=virtio-rnd
pci.0.31.0.device=lpc
lpc.com1.path=/dev/nmdm%(link)A

bootrom=/usr/local/share/uefi-firmware/BHYVE_UEFI.fd
```

- [ ] **Step 2: Update README**

In the examples list (after the `pod-cloudinit.conf` bullet, line ~61), add:

```markdown
- [`pod-installer.conf`](examples/pod-installer.conf) — template with an AHCI-CD
  device that boots an installer ISO via the `%(iso)` variable
```

In the Provisioning section, after the existing three `vmctl create` sample lines (~line 104), add a fourth sample and a paragraph:

```markdown
    vmctl create pod36 --network labs_vlan50 --config pod-installer.conf --iso /bhyve/isos/freebsd-14.3.iso --start

`--iso FILE` attaches an installer ISO: the path is stored (absolute) as `iso:`
in the inventory and passed to bhyve as `-o iso=...` on every start. The VM's
template must consume the `%(iso)` variable (see
[`pod-installer.conf`](examples/pod-installer.conf)); `create` and `start`
refuse a VM whose `iso:` and template don't agree. The ISO is referenced in
place — never copied — and stays attached until you remove the `iso:` line;
with UEFI this is harmless once the installed disk boots first.
```

- [ ] **Step 3: Run full suite (docs must not break anything)**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: 128 runs, 0 failures, 0 errors.

- [ ] **Step 4: Commit** (sandbox disabled for git)

```bash
git add examples/pod-installer.conf README.md
git commit -m "docs: installer template example and create --iso docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
