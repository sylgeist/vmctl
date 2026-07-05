# Cloud-init Fully Inventory-Driven Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate the installer-ISO and cloud-init seed CD devices in the renderer (deleting the special flavors and the iso-pairing machinery), and make cloud-init user-data dynamic via a `config_dir` template + per-VM `vars`, with `--var` and `set --cloud-init`/`--no-cloud-init`.

**Architecture:** CDs join disks/NICs as generated `ConfigRenderer` keys (`pci.0.5` installer, `pci.0.6` seed). `CloudInit` renders user-data by substituting `%()` from built-ins + `vars` before packing the NoCloud seed. `instance-id` stays `= <vm name>` (stable); the seed ISO is rebuilt by `create`/`set`, not per-start. Two phases: **A** (CDs + pairing removal + migration), **B** (dynamic user-data).

**Tech Stack:** Ruby stdlib, minitest, `FakeExecutor`.

## Global Constraints

- Ruby 4.0 (CI: `ruby -Ilib -Itest test/run_all.rb`). No new gem dependencies.
- Source files start with `# frozen_string_literal: true` + `# lib/vmctl/<path>`.
- Tests are minitest under `test/`, using `FakeExecutor` (records argv arrays). Single file: `ruby -Ilib -Itest test/test_x.rb`. Full suite: `ruby -Ilib -Itest test/run_all.rb`.
- CD slots: installer ISO `pci.0.5.0` (ahci, `ro=true`); cloud-init seed `pci.0.6.0` (ahci, no ro). Both generated only when `iso:`/`cloud_init:` is set.
- User-data template resolution: absolute path as-is, else `File.join(config_dir, user_data)`. `vars` win over built-ins (`name/network/link/mac`) on key collision. `instance-id`/`local-hostname` = `name` (unchanged).
- User-facing errors are `VMCtl::Commands::CommandError`; load-time schema errors `VMCtl::ConfigError`.
- Git commits end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Branch `feat/cloud-init-dynamic`.

---

# Phase A — generate CD devices; remove pairing

## Task 1: shared `VMCtl.substitute` helper

**Files:**
- Create: `lib/vmctl/substitution.rb`
- Modify: `lib/vmctl/config_renderer.rb`
- Test: `test/test_substitution.rb`

**Interfaces:**
- Produces: `VMCtl.substitute(text, vars)` → String; replaces `%(word)` from `vars` (string keys), passing unknown tokens through. `ConfigRenderer#substitute` delegates to it.

- [ ] **Step 1: Write the failing test** — `test/test_substitution.rb`:

```ruby
# frozen_string_literal: true
# test/test_substitution.rb
require 'test_helper'
require 'vmctl/substitution'

class TestSubstitution < Minitest::Test
  def test_replaces_known_tokens
    assert_equal 'a=1 b=2', VMCtl.substitute('a=%(x) b=%(y)', 'x' => '1', 'y' => '2')
  end

  def test_unknown_token_passes_through
    assert_equal 'keep %(z)', VMCtl.substitute('keep %(z)', 'x' => '1')
  end

  def test_tolerates_non_ascii_bytes
    out = VMCtl.substitute(+"# \xE2\x80\x94 %(x)\n".b, 'x' => 'ok')
    assert_includes out, 'ok'
  end
end
```

- [ ] **Step 2: Run — FAIL** (`cannot load such file -- vmctl/substitution`).

- [ ] **Step 3: Implement** — `lib/vmctl/substitution.rb`:

```ruby
# frozen_string_literal: true
# lib/vmctl/substitution.rb
module VMCtl
  # Replace %(word) tokens from vars (string keys); unknown tokens pass through.
  def self.substitute(text, vars)
    text.gsub(/%\((\w+)\)/) { vars.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
  end
end
```

In `lib/vmctl/config_renderer.rb`, add `require_relative 'substitution'` at the top (after the header comment) and replace the private `substitute` method:

```ruby
    def substitute(text, entry)
      VMCtl.substitute(text,
                       'name'    => entry.name.to_s,
                       'network' => entry.network.to_s,
                       'link'    => entry.link.to_s,
                       'mac'     => entry.mac.to_s,
                       'iso'     => entry.iso.to_s)
    end
```

- [ ] **Step 4: Run** `ruby -Ilib -Itest test/test_substitution.rb && ruby -Ilib -Itest test/test_config_renderer.rb` → PASS (renderer behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/substitution.rb lib/vmctl/config_renderer.rb test/test_substitution.rb
git commit -m "$(printf 'refactor: extract shared VMCtl.substitute helper\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 2: generate iso + seed CD devices

**Files:**
- Modify: `lib/vmctl/config_renderer.rb`
- Test: `test/test_config_renderer.rb`

**Interfaces:**
- Produces: `ConfigRenderer` emits `pci.0.5.0.*` when `entry.iso` set and `pci.0.6.0.*` when `entry.cloud_init` set (appended to the generator list).

- [ ] **Step 1: Write failing tests** — add to `test/test_config_renderer.rb` (the `entry` helper already accepts `iso:`; use its keyword. For cloud_init, pass it via the helper — extend the helper with a `cloud_init: nil` kwarg passed to `VMEntry.new`):

```ruby
  def test_iso_cd_generated_when_iso_set
    out = render("cpus=2\n", entry(disks: [], iso: '/bhyve/isos/x.iso'))
    assert_match(/^pci\.0\.5\.0\.device=ahci$/, out)
    assert_match(/^pci\.0\.5\.0\.port\.0\.type=cd$/, out)
    assert_match(/^pci\.0\.5\.0\.port\.0\.ro=true$/, out)
    assert_match(%r{^pci\.0\.5\.0\.port\.0\.path=/bhyve/isos/x\.iso$}, out)
  end

  def test_no_iso_cd_when_absent
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.5\./, out)
  end

  def test_seed_cd_generated_when_cloud_init_set
    out = render("cpus=2\n", entry(disks: [], cloud_init: { 'user_data' => 'x.yml' }))
    assert_match(/^pci\.0\.6\.0\.device=ahci$/, out)
    assert_match(/^pci\.0\.6\.0\.port\.0\.type=cd$/, out)
    assert_match(%r{^pci\.0\.6\.0\.port\.0\.path=/bhyve/pod34/pod34-seed\.iso$}, out)
    refute_match(/^pci\.0\.6\.0\.port\.0\.ro=/, out)   # seed CD is read-write
  end

  def test_no_seed_cd_when_absent
    out = render("cpus=2\n", entry(disks: []))
    refute_match(/pci\.0\.6\./, out)
  end

  def test_iso_and_seed_cds_coexist
    out = render("cpus=2\n", entry(disks: [], iso: '/i.iso', cloud_init: { 'user_data' => 'x.yml' }))
    assert_match(/^pci\.0\.5\.0\.device=ahci$/, out)
    assert_match(/^pci\.0\.6\.0\.device=ahci$/, out)
  end
```

Extend the `entry` helper to accept `cloud_init: nil` and pass it to `VMEntry.new`.

- [ ] **Step 2: Run** `ruby -Ilib -Itest test/test_config_renderer.rb -n test_seed_cd_generated_when_cloud_init_set` → FAIL (no CD keys).

- [ ] **Step 3: Implement** — in `lib/vmctl/config_renderer.rb`, extend the generator list and add the two generators:

```ruby
    def generators
      [method(:disk_keys), method(:net_keys), method(:iso_cd_keys), method(:seed_cd_keys)]
    end

    # Installer ISO CD (read-only), generated when the VM has an iso:.
    def iso_cd_keys(vm)
      return {} unless vm.entry.iso
      {
        'pci.0.5.0.device'      => 'ahci',
        'pci.0.5.0.port.0.type' => 'cd',
        'pci.0.5.0.port.0.ro'   => 'true',
        'pci.0.5.0.port.0.path' => vm.entry.iso
      }
    end

    # NoCloud cloud-init seed CD, generated when the VM has cloud_init:.
    def seed_cd_keys(vm)
      return {} unless vm.entry.cloud_init
      {
        'pci.0.6.0.device'      => 'ahci',
        'pci.0.6.0.port.0.type' => 'cd',
        'pci.0.6.0.port.0.path' => File.join(vm.dir, "#{vm.name}-seed.iso")
      }
    end
```

- [ ] **Step 4: Run** `ruby -Ilib -Itest test/test_config_renderer.rb && ruby -Ilib -Itest test/run_all.rb` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config_renderer.rb test/test_config_renderer.rb
git commit -m "$(printf 'feat: generate installer/seed CD devices from inventory (pci.0.5/0.6)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 3: remove the iso-pairing machinery

**Files:**
- Modify: `lib/vmctl/commands/base.rb`, `lib/vmctl/vm.rb`, `lib/vmctl/commands/create.rb`, `lib/vmctl/commands/start.rb`, `lib/vmctl/commands/set.rb`
- Test: `test/test_vm.rb`, `test/test_create_command.rb`, `test/test_commands.rb`, `test/test_set_command.rb`

**Interfaces:** removes `Commands::Base#validate_iso_pairing!` and `VM#template_wants_iso?`. A VM with `iso:` now renders a CD on any flavor (Task 2); pairing is obsolete.

- [ ] **Step 1: Delete the tests that assert the removed behavior**

- `test/test_vm.rb`: delete all five `test_template_wants_iso_*` methods (lines ~73–113).
- `test/test_create_command.rb`: delete `test_create_rejects_iso_when_template_lacks_reference` and `test_create_rejects_installer_template_without_iso`. Keep `write_installer_template`/`write_iso` and the iso-recording tests (they still pass — iso is recorded and its file validated; no pairing).
- `test/test_commands.rb`: delete `test_start_rejects_iso_when_template_lacks_reference` and `test_start_rejects_installer_template_without_iso`, and the now-unused helpers `config_for_iso` and `never_start_factory`.
- `test/test_set_command.rb`: delete `test_set_iso_requires_pairing`. Keep `test_set_iso_with_installer_template` (setting `--config`+`--iso` still works; it no longer validates pairing).

- [ ] **Step 2: Run — expect failures only from the removed methods still being referenced**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: the deleted tests are gone; the suite still passes because the production methods still exist. (This step confirms you removed only the intended tests. If a kept test fails, investigate before Step 3.)

- [ ] **Step 3: Remove the production methods and their calls**

- `lib/vmctl/commands/base.rb`: delete the `validate_iso_pairing!` method (and its leading comment).
- `lib/vmctl/vm.rb`: delete the `template_wants_iso?` method (and its comment).
- `lib/vmctl/commands/create.rb`: delete the `validate_iso_pairing!(vm)` line in `validate!`.
- `lib/vmctl/commands/start.rb`: delete the `validate_iso_pairing!(vm)` line in `start_one`.
- `lib/vmctl/commands/set.rb`: in `apply_iso!`, delete the `validate_iso_pairing!(vm)` line (the `else` branch keeps expand/exists/set).

- [ ] **Step 4: Run full suite** — `ruby -Ilib -Itest test/run_all.rb` → PASS. Confirm no references remain: `grep -rn 'validate_iso_pairing!\|template_wants_iso?' lib/ test/` → empty.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/base.rb lib/vmctl/vm.rb lib/vmctl/commands/create.rb lib/vmctl/commands/start.rb lib/vmctl/commands/set.rb test/test_vm.rb test/test_create_command.rb test/test_commands.rb test/test_set_command.rb
git commit -m "$(printf 'refactor: drop iso-pairing validation (CD now generated from inventory)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 4: migrate example flavors + README

**Files:**
- Delete: `examples/pod-installer.conf`, `examples/pod-cloudinit.conf`
- Modify: `examples/pod.conf`, `examples/inventory.yml`, `README.md`
- Test: none (run full suite to confirm nothing load-bearing broke).

- [ ] **Step 1: Delete the special flavors**

```bash
git rm examples/pod-installer.conf examples/pod-cloudinit.conf
```

- [ ] **Step 2: Update `examples/pod.conf` header** — note that installer-ISO and cloud-init seed CDs are also generated from the inventory (`iso:` / `cloud_init:`); templates declare no `pci.0.3/0.4/0.5/0.6` devices at all — only OS-core (cpus/memory/bootrom/hostbridge/rng/lpc console).

- [ ] **Step 3: Update `examples/inventory.yml`** — change the cloud-init VM to use `config: pod.conf` (not the deleted flavor) with:
```yaml
    cloud_init:
      user_data: web-base.yml     # a template in config_dir
      vars:
        role: web
```
and add a short comment showing an `iso:` VM also on `pod.conf`.

- [ ] **Step 4: Update `README.md`** — document that installer/seed CDs are generated (`pci.0.5`/`pci.0.6`) from `iso:`/`cloud_init:`, templates need no CD/`%(iso)` lines, and there is no template/iso pairing requirement anymore.

- [ ] **Step 5: Run** `ruby -Ilib -Itest test/run_all.rb` → PASS (examples aren't loaded by tests).

- [ ] **Step 6: Commit**

```bash
git add -A examples README.md
git commit -m "$(printf 'docs: drop installer/cloud-init flavors; CDs generated from inventory\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

# Phase B — dynamic user-data

## Task 5: `cloud_init` schema validation (user_data + vars)

**Files:**
- Modify: `lib/vmctl/config.rb`
- Test: `test/test_config.rb`

**Interfaces:** `parse_cloud_init` — when `cloud_init` present, `user_data` must be a non-empty String and `vars` (optional) a mapping → else `ConfigError`. `cloud_init` stays a Hash; `vm_to_h` unchanged (emits when set).

- [ ] **Step 1: Write failing tests** — add to `test/test_config.rb`:

```ruby
  def test_cloud_init_parses_user_data_and_vars
    inv = <<~YAML
      defaults: { config_dir: /c, vm_root: /v, zpool: tank, link_base: 10 }
      vms:
        pod34:
          network: n
          link: 10
          disks: []
          cloud_init:
            user_data: web-base.yml
            vars: { role: web }
    YAML
    cfg = VMCtl::Config.load(write_inventory(inv).path)
    ci = cfg.vms.fetch('pod34').cloud_init
    assert_equal 'web-base.yml', ci['user_data']
    assert_equal({ 'role' => 'web' }, ci['vars'])
  end

  def test_cloud_init_requires_user_data
    inv = "vms:\n  p:\n    network: n\n    link: 10\n    disks: []\n    cloud_init: { vars: {} }\n"
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(write_inventory(inv).path) }
  end

  def test_cloud_init_vars_must_be_mapping
    inv = "vms:\n  p:\n    network: n\n    link: 10\n    disks: []\n    cloud_init: { user_data: u, vars: 5 }\n"
    assert_raises(VMCtl::ConfigError) { VMCtl::Config.load(write_inventory(inv).path) }
  end
```

- [ ] **Step 2: Run** → FAIL (no validation; `test_cloud_init_requires_user_data` loads without raising).

- [ ] **Step 3: Implement** — in `lib/vmctl/config.rb`, change `parse_vm`'s cloud_init line to `cloud_init: parse_cloud_init(body['cloud_init'])` and add:

```ruby
    def parse_cloud_init(ci)
      return nil if ci.nil?
      raise ConfigError, "'cloud_init' must be a mapping" unless ci.is_a?(Hash)
      if ci['user_data'].to_s.empty?
        raise ConfigError, "'cloud_init' needs a 'user_data' template"
      end
      vars = ci['vars']
      raise ConfigError, "'cloud_init.vars' must be a mapping" unless vars.nil? || vars.is_a?(Hash)
      ci
    end
```

- [ ] **Step 4: Run** `ruby -Ilib -Itest test/test_config.rb` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/config.rb test/test_config.rb
git commit -m "$(printf 'feat(config): validate cloud_init user_data + vars\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 6: `CloudInit` renders user-data (template + vars)

**Files:**
- Modify: `lib/vmctl/cloudinit.rb`
- Test: `test/test_cloudinit.rb`

**Interfaces:** `CloudInit#render_user_data(vm, text, vars)` (public, pure) → rendered String (built-ins `name/network/link/mac` + `vars`, vars win). `CloudInit#build_seed(vm, template_path, vars = {})` reads the template, renders, packs `meta-data` + rendered user-data into an ephemeral seed dir, and `makefs` → `<vm.dir>/<name>-seed.iso`. No `vm.dir` copy. `meta_data_for` unchanged. `populate_seed` removed.

- [ ] **Step 1: Rewrite `test/test_cloudinit.rb`** — test the pure `render_user_data` directly, plus that `build_seed` runs makefs:

```ruby
# frozen_string_literal: true
# test/test_cloudinit.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/vm'
require 'vmctl/cloudinit'
require 'tmpdir'

class TestCloudInit < Minitest::Test
  def vm(dir: '/bhyve')
    defaults = VMCtl::Defaults.new(
      config_dir: '/bhyve/configs', vm_root: dir, zpool: 'tank/bhyve',
      template: 'pod.conf', link_base: 10, run_dir: '/var/run/vmctl',
      log_dir: '/var/log/vmctl', image_dir: '/bhyve/images', root_size: '20G', root_from: nil
    )
    entry = VMCtl::VMEntry.new(name: 'pod35', config: 'pod.conf', network: 'labs',
                               link: 12, mac: nil, autostart: false, disks: [], cloud_init: nil)
    VMCtl::VM.new(entry, defaults)
  end

  def test_meta_data_has_instance_id_and_hostname
    md = VMCtl::CloudInit.new(FakeExecutor.new).meta_data_for('pod35')
    assert_match(/instance-id:\s*pod35/, md)
    assert_match(/local-hostname:\s*pod35/, md)
  end

  def test_render_user_data_substitutes_builtins_and_vars
    out = VMCtl::CloudInit.new(FakeExecutor.new).render_user_data(
      vm, "hostname: %(name)\nrole: %(role)\nnet: %(network)\n", 'role' => 'web'
    )
    assert_match(/^hostname: pod35$/, out)
    assert_match(/^role: web$/, out)
    assert_match(/^net: labs$/, out)
  end

  def test_render_user_data_vars_override_builtins
    out = VMCtl::CloudInit.new(FakeExecutor.new).render_user_data(vm, "n: %(name)\n", 'name' => 'override')
    assert_match(/^n: override$/, out)
  end

  def test_build_seed_reads_template_and_runs_makefs_to_vm_dir
    Dir.mktmpdir do |root|
      tmpl = File.join(root, 'tmpl.yml')
      File.write(tmpl, "#cloud-config\nhostname: %(name)\n")
      exec = FakeExecutor.new
      v = vm(dir: root)   # vm.dir need not exist: makefs is faked
      iso = VMCtl::CloudInit.new(exec).build_seed(v, tmpl, {})
      assert_equal File.join(v.dir, 'pod35-seed.iso'), iso
      cmd = exec.runs.find { |a| a.first == 'makefs' }
      refute_nil cmd, 'makefs must run'
      assert_includes cmd, iso
    end
  end
end
```

- [ ] **Step 2: Run** `ruby -Ilib -Itest test/test_cloudinit.rb` → FAIL (no `render_user_data`; old `build_seed` behavior).

- [ ] **Step 3: Implement** — in `lib/vmctl/cloudinit.rb` add `require_relative 'substitution'`, keep `meta_data_for`, delete `populate_seed`, and replace `build_seed`:

```ruby
    # Renders user-data (built-ins + vars) and packs a NoCloud seed ISO.
    # Returns the ISO path (<vm.dir>/<name>-seed.iso).
    def build_seed(vm, template_path, vars = {})
      rendered = render_user_data(vm, File.read(template_path), vars)
      iso = File.join(vm.dir, "#{vm.name}-seed.iso")
      Dir.mktmpdir('vmctl-seed') do |seeddir|
        File.write(File.join(seeddir, 'meta-data'), meta_data_for(vm.name))
        File.write(File.join(seeddir, 'user-data'), rendered)
        @exec.run('makefs', '-t', 'cd9660', '-o', 'rockridge,label=cidata', iso, seeddir)
      end
      iso
    end

    # Public + pure: substitutes %() from built-ins (name/network/link/mac) plus
    # the operator vars (vars win). The testable seam.
    def render_user_data(vm, text, vars)
      e = vm.entry
      builtins = { 'name' => vm.name, 'network' => e.network.to_s,
                   'link' => e.link.to_s, 'mac' => e.mac.to_s }
      VMCtl.substitute(text, builtins.merge(stringify(vars)))
    end

    private

    def stringify(vars)
      (vars || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
    end
```

- [ ] **Step 4: Run** `ruby -Ilib -Itest test/test_cloudinit.rb && ruby -Ilib -Itest test/run_all.rb` → PASS. (`build_seed`'s new signature is call-compatible with create's existing 2-arg call, and it no longer needs `vm.dir` to exist, so the old `create` cloud-init test stays green until B3 replaces it.)

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/cloudinit.rb test/test_cloudinit.rb
git commit -m "$(printf 'feat(cloudinit): render user-data from template + vars\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 7: `create --cloud-init <template> --var K=V`

**Files:**
- Modify: `lib/vmctl/commands/create.rb`
- Test: `test/test_create_command.rb`

**Interfaces:** `create` resolves the template (config_dir or absolute), builds the seed with `vars`, sets `entry.cloud_init = { 'user_data' => <template>, 'vars' => vars }` (omitting `vars` when empty).

- [ ] **Step 1: Write/replace failing tests** — replace `test_create_cloud_init_records_field_and_builds_seed` and add a `--var` test:

```ruby
  def test_create_cloud_init_builds_seed_and_records_template
    File.write(File.join(@config_dir, 'web-base.yml'), "#cloud-config\nhostname: %(name)\n")
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--cloud-init', 'web-base.yml']) }
    assert(exec.runs.any? { |a| a.first == 'makefs' })
    ci = VMCtl::Config.load(@inv).vms.fetch('pod35').cloud_init
    assert_equal 'web-base.yml', ci['user_data']
    refute ci.key?('vars')
  end

  def test_create_cloud_init_with_vars
    File.write(File.join(@config_dir, 'web-base.yml'), "#cloud-config\nrole: %(role)\n")
    exec = bridge_ok
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: exec)
    capture_stdout { cmd.call(['pod35', '--network', 'labs_vlan50', '--cloud-init', 'web-base.yml', '--var', 'role=web']) }
    ci = VMCtl::Config.load(@inv).vms.fetch('pod35').cloud_init
    assert_equal({ 'role' => 'web' }, ci['vars'])
  end

  def test_create_rejects_missing_cloud_init_template
    cmd = VMCtl::Commands::Create.new(config: load_config, executor: bridge_ok)
    err = assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod35', '--network', 'labs_vlan50', '--cloud-init', 'nope.yml'])
    end
    assert_match(/cloud-init template not found/, err.message)
  end
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement** — in `lib/vmctl/commands/create.rb`:

Add options to `parse` (inside the OptionParser block; `o[:vars]` starts `{}`):
```ruby
          p.on('--var KV') { |v| k, val = v.split('=', 2); raise CommandError, "invalid --var #{v.inspect}" unless k =~ /\A\w+\z/ && val; o[:vars][k] = val }
```
Initialize `o = { disks: [], vars: {} }` at the top of `parse`.

In `validate!`, replace the old cloud-init existence check with a template-resolution check:
```ruby
        if opts[:cloud_init] && !File.exist?(cloud_init_template(opts[:cloud_init]))
          raise CommandError, "cloud-init template not found: #{cloud_init_template(opts[:cloud_init])}"
        end
```

Replace the `cloud_init` method and add the resolver:
```ruby
      def cloud_init(vm, entry, template, vars)
        CloudInit.new(executor).build_seed(vm, cloud_init_template(template), vars)
        entry.cloud_init = { 'user_data' => template }
        entry.cloud_init['vars'] = vars unless vars.empty?
      end

      def cloud_init_template(t)
        File.absolute_path?(t) ? t : File.join(config.defaults.config_dir, t)
      end
```

Update the call in `call`: `cloud_init(vm, entry, opts[:cloud_init], opts[:vars]) if opts[:cloud_init]`.

- [ ] **Step 4: Run** `ruby -Ilib -Itest test/test_create_command.rb && ruby -Ilib -Itest test/run_all.rb` → PASS (this also re-greens the B2-noted failure).

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/create.rb test/test_create_command.rb
git commit -m "$(printf 'feat(create): --cloud-init template + --var vars, render seed\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 8: `set --cloud-init` / `--var` / `--no-cloud-init`

**Files:**
- Modify: `lib/vmctl/commands/set.rb`
- Test: `test/test_set_command.rb`

**Interfaces:** `set --cloud-init <template>` and/or `--var K=V` update `entry.cloud_init` and rebuild the seed; `set --no-cloud-init` clears it (leaves the seed file).

- [ ] **Step 1: Write failing tests** — add to `test/test_set_command.rb`. The `setup` already writes `@dir` as `config_dir`; put templates there. `build_seed` doesn't write to `vm.dir` (makefs is faked), so no `vm.dir` setup is needed.

```ruby
  def test_set_cloud_init_builds_seed_and_records
    File.write(File.join(@dir, 'base.yml'), "#cloud-config\nhostname: %(name)\n")
    exec = stopped
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: exec)
    capture_stdout { cmd.call(['pod34', '--cloud-init', 'base.yml']) }
    ci = VMCtl::Config.load(@inv).vms.fetch('pod34').cloud_init
    assert_equal 'base.yml', ci['user_data']
    assert(exec.runs.any? { |a| a.first == 'makefs' })
  end

  def test_set_var_updates_and_rebuilds
    File.write(File.join(@dir, 'base.yml'), "role: %(role)\n")
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    capture_stdout { cmd.call(['pod34', '--cloud-init', 'base.yml', '--var', 'role=web']) }
    ci = VMCtl::Config.load(@inv).vms.fetch('pod34').cloud_init
    assert_equal({ 'role' => 'web' }, ci['vars'])
  end

  def test_set_no_cloud_init_clears
    File.write(File.join(@dir, 'base.yml'), "x: 1\n")
    VMCtl::Commands::Set.new(config: cfg, executor: stopped).tap do |c|
      capture_stdout { c.call(['pod34', '--cloud-init', 'base.yml']) }
      capture_stdout { c.call(['pod34', '--no-cloud-init']) }
    end
    assert_nil VMCtl::Config.load(@inv).vms.fetch('pod34').cloud_init
  end

  def test_set_cloud_init_rejects_missing_template
    cmd = VMCtl::Commands::Set.new(config: cfg, executor: stopped)
    err = assert_raises(VMCtl::Commands::CommandError) { cmd.call(['pod34', '--cloud-init', 'nope.yml']) }
    assert_match(/cloud-init template not found/, err.message)
  end
```

(In `test_set_no_cloud_init_clears` both `c.call`s share one `Set`/config instance, so the second call sees the cloud_init the first set in memory, then clears and saves it.)

- [ ] **Step 2: Run** → FAIL (no `--cloud-init` on set).

- [ ] **Step 3: Implement** — in `lib/vmctl/commands/set.rb`:

Add to the parser:
```ruby
          p.on('--cloud-init TMPL') { |v| opts[:cloud_init] = v }
          p.on('--no-cloud-init')   { opts[:cloud_init] = false }
          p.on('--var KV')          { |v| (opts[:vars] ||= {}); k, val = v.split('=', 2); raise CommandError, "invalid --var #{v.inspect}" unless k =~ /\A\w+\z/ && val; opts[:vars][k] = val }
```

In `apply!`, add a cloud-init branch (after the iso branch):
```ruby
        apply_cloud_init!(vm, opts, changed) if opts.key?(:cloud_init) || opts.key?(:vars)
```

Add the private helpers (reuse `require_relative '../cloudinit'`):
```ruby
      def apply_cloud_init!(vm, opts, changed)
        e = vm.entry
        if opts[:cloud_init] == false
          e.cloud_init = nil
          changed << 'cloud_init=(none)'
          return
        end
        ci = e.cloud_init ? e.cloud_init.dup : {}
        ci['user_data'] = opts[:cloud_init] if opts[:cloud_init]
        raise CommandError, 'set --var requires cloud-init on the VM' if ci['user_data'].to_s.empty?
        vars = (ci['vars'] || {}).merge(opts[:vars] || {})
        template = cloud_init_template(ci['user_data'])
        raise CommandError, "cloud-init template not found: #{template}" unless File.exist?(template)
        CloudInit.new(executor).build_seed(vm, template, vars)
        ci['vars'] = vars unless vars.empty?
        e.cloud_init = ci
        changed << "cloud_init=#{ci['user_data']}"
      end

      def cloud_init_template(t)
        File.absolute_path?(t) ? t : File.join(config.defaults.config_dir, t)
      end
```

- [ ] **Step 4: Run** `ruby -Ilib -Itest test/test_set_command.rb && ruby -Ilib -Itest test/run_all.rb` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/vmctl/commands/set.rb test/test_set_command.rb
git commit -m "$(printf 'feat(set): --cloud-init/--var/--no-cloud-init with seed rebuild\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] Full suite: `ruby -Ilib -Itest test/run_all.rb` → all PASS.
- [ ] `grep -rn 'validate_iso_pairing!\|template_wants_iso?\|populate_seed' lib/ test/` → empty.
- [ ] `ruby -Ilib bin/vmctl help` still renders; `git log --oneline` shows the 8 task commits on `feat/cloud-init-dynamic`.

## Notes for the implementer

- Phase A leaves cloud-init building the seed **verbatim** (create still uses the old copy path until B3) — that's fine; A2's `seed_cd_keys` only checks `entry.cloud_init` presence, so it works with the old `{ user_data: ... }` shape.
- `--var K=V` splits on the first `=`; `K` must match `\A\w+\z`. `vars` values are strings.
- Only gate `config.save` behind `unless executor.dry_run?`; `build_seed`/`makefs` run through the executor (no-op under dry-run).
- `File.absolute_path?` (Ruby 3.1+) distinguishes an absolute template path from a config_dir-relative name.
