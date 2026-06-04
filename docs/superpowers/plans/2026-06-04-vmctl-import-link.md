# vmctl `import --link N` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional `--link N` flag to `vmctl import` that pins the VM's link (allowing any unused value, including below `link_base`) instead of auto-allocating — the migration path for adopting existing in-place VMs without changing their console/netgraph link.

**Architecture:** Add a `--link N` (Integer) option to `Import`'s parser and resolve the link via a small branch: pinned link is validated against `Allocator#link_taken?` (collision → `CommandError`) and used as-is; omitted falls back to `Allocator#next_link` (unchanged).

**Tech Stack:** Ruby (stdlib only), minitest. Modifies the existing `Commands::Import`.

**Spec:** `docs/superpowers/specs/2026-06-04-vmctl-import-link-design.md`.

**Conventions:** `VMCtl` namespace; `Executor` boundary; thin commands; tests via `ruby -Ilib -Itest test/run_all.rb`. Git commits require the sandbox disabled — implementers should NOT commit; the controller commits.

**Existing code (verified against `main`, `lib/vmctl/commands/import.rb`):**
- `Import#call` builds a `VMEntry` with `link: Allocator.new(config).next_link`.
- `Import#parse` uses `OptionParser` with `--network`/`--config`/`--mac`, then `o[:name] = rest.shift`.
- `Allocator.new(config)` → `next_link`, `link_taken?(n)`.

---

## File Structure

```
lib/vmctl/commands/import.rb   # MODIFY: add --link option + link resolver
test/test_import_command.rb    # MODIFY: add pin + collision tests
README.md                      # MODIFY: add an "Adopting existing VMs" note
```

---

## Task 1: `import --link N`

**Files:** Modify `lib/vmctl/commands/import.rb`, `test/test_import_command.rb`, `README.md`

- [ ] **Step 1: Add failing tests** — append inside `class TestImportCommand` in `test/test_import_command.rb` (before its final `end`):

```ruby
  def test_import_link_pins_below_base
    make_disks('pod40', ['pod40-root.raw', 1024])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    capture_stdout { cmd.call(['pod40', '--network', 'labs_vlan50', '--link', '8']) }
    assert_equal 8, VMCtl::Config.load(@inv).vms.fetch('pod40').link
  end

  def test_import_link_rejects_collision
    make_disks('pod40', ['pod40-root.raw', 1024])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    # link 10 is already used by the `existing` VM in the fixture inventory.
    err = assert_raises(VMCtl::Commands::CommandError) do
      cmd.call(['pod40', '--network', 'labs_vlan50', '--link', '10'])
    end
    assert_match(/already in use/, err.message)
  end

  def test_import_rejects_non_integer_link
    make_disks('pod40', ['pod40-root.raw', 1024])
    cmd = VMCtl::Commands::Import.new(config: load_config, executor: FakeExecutor.new)
    assert_raises(OptionParser::ParseError) do
      cmd.call(['pod40', '--network', 'labs_vlan50', '--link', 'notanumber'])
    end
  end
```

(`load_config`'s fixture already defines an `existing` VM on link 10 with `link_base: 10`, so a pinned `8` is below base and `10` collides.)

- [ ] **Step 2: Run, confirm failure**

Run: `ruby -Ilib -Itest test/test_import_command.rb`
Expected: FAIL — `--link` is an unknown option (`OptionParser::InvalidOption`) for the pin/collision tests.

- [ ] **Step 3: Implement** — two edits in `lib/vmctl/commands/import.rb`.

(a) Add the `--link` option to the parser. Change the `parse` method's `OptionParser.new` block to include it:
```ruby
        parser = OptionParser.new do |p|
          p.on('--network NET') { |v| o[:network] = v }
          p.on('--config TMPL') { |v| o[:config] = v }
          p.on('--mac MAC')     { |v| o[:mac] = v }
          p.on('--link N', Integer) { |v| o[:link] = v }
        end
```

(b) Resolve the link before building the entry. In `call`, replace this line inside the `VMEntry.new(...)`:
```ruby
          link: Allocator.new(config).next_link,
```
with a reference to a resolved local:
```ruby
          link: resolve_link(opts),
```
and add this private method (next to `parse`):
```ruby
      def resolve_link(opts)
        allocator = Allocator.new(config)
        return allocator.next_link unless opts[:link]
        if allocator.link_taken?(opts[:link])
          raise CommandError, "link #{opts[:link]} already in use"
        end
        opts[:link]
      end
```

- [ ] **Step 4: Run, confirm pass**

Run: `ruby -Ilib -Itest test/test_import_command.rb`
Expected: PASS — existing import tests plus the 3 new ones.

- [ ] **Step 5: Run the full suite**

Run: `ruby -Ilib -Itest test/run_all.rb`
Expected: PASS — all green.

- [ ] **Step 6: Update `README.md`** — add an "Adopting existing VMs" note. Insert it in the Provisioning section, right after the paragraph that begins "`import <name> --network NET` adopts a VM whose dataset already exists":

```markdown

To adopt a VM that's **already on this host** (started by hand or an old
script), pin its current link so its console (`/dev/nmdm<link>`) and netgraph
hook don't move:

    vmctl import pod34 --network labs_vlan50 --link 8

`--link` accepts any unused link (including the 0-9 band reserved from
auto-allocation). Omit it to auto-allocate the lowest free link. After importing,
stop the VM the old way once, then `vmctl start pod34` so vmctl's supervisor
takes over.
```

- [ ] **Step 7: Smoke-check the binary**

Run:
```bash
TMP=$(mktemp -d "$TMPDIR/vmctl.XXXXXX"); mkdir -p "$TMP/vms/pod34"
: > "$TMP/vms/pod34/pod34-root.raw"
printf 'defaults:\n  vm_root: %s/vms\n  zpool: tank/bhyve\n  template: pod.conf\n  link_base: 10\nvms: {}\n' "$TMP" > "$TMP/inv.yml"
ruby -Ilib bin/vmctl -c "$TMP/inv.yml" import pod34 --network labs_vlan50 --link 8
grep -A1 'pod34:' "$TMP/inv.yml" | grep -i link
```
Expected: prints `imported pod34 (link 8, 1 disk(s))` and the inventory shows `link: 8`.

- [ ] **Step 8: Commit-prep** — leave uncommitted; controller commits.

---

## Self-Review

**Spec coverage:**
- `--link N` pins the link, accepts below-`link_base` values → Task 1 Step 1 (`test_import_link_pins_below_base`) + Step 3.
- Collision → `CommandError` via `Allocator#link_taken?` → Step 1 (`test_import_link_rejects_collision`) + `resolve_link`.
- Omitted → `next_link` unchanged → existing `test_import_scans_disks_and_allocates_fresh_link` still passes (Step 5).
- Non-integer → `OptionParser::ParseError` (CLI exit 2) → Step 1 (`test_import_rejects_non_integer_link`).
- README migration note → Step 6.

**Placeholder scan:** None — every step has complete code.

**Type consistency:** `resolve_link(opts)` (defined Step 3) is referenced in the same `VMEntry` it feeds; `opts[:link]`, `Allocator#link_taken?`/`#next_link`, and `CommandError` all match existing signatures.
