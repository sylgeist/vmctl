# vmctl `dump` command — Design

**Date:** 2026-06-04
**Status:** Approved design, pre-implementation
**Builds on:** Phase 1 (lifecycle) + Phase 2 (provisioning), both on `main`.

## Summary

Add `vmctl dump <name>`, a read-only discovery command that prints a VM's
fully-resolved bhyve configuration. It runs bhyve with `config.dump=1` appended
to the usual invocation; bhyve prints the merged configuration (the template's
`pci.*` lines, the `-o` substitutions, and bhyve's own defaults) and exits
**without booting**. vmctl captures and prints that output.

This is a debugging/discovery aid: it shows exactly what bhyve sees after
templating, which is otherwise invisible.

## Behavior

```
vmctl dump pod34
```
runs (synchronously, read-only):
```
bhyve -k /bhyve/configs/pod.conf -o network=labs_vlan50 -o link=10 -o config.dump=1 pod34
```
and prints bhyve's resolved-config output. `config.dump=1` causes bhyve to dump
the configuration and exit before device setup, so the command:

- needs **no** netgraph bridge to exist,
- needs **no** disks to exist,
- does **not** fork a supervisor or create a VM,
- has no side effects (safe to run anytime, including against a running VM —
  it does not touch the running instance).

## Components

- **`VM#dump_command`** — reuses the existing `bhyve_argv` and inserts
  `-o config.dump=1` immediately before the VM name (so it lands after an
  `-o mac=…` when a MAC is set). Returns the joined command string. Keeps `VM`
  the single place that renders bhyve invocations.
  ```ruby
  def dump_command
    argv = bhyve_argv
    argv.insert(-2, '-o', 'config.dump=1')
    argv.join(' ')
  end
  ```
- **`Commands::Dump < Base`** — thin handler:
  ```ruby
  def call(args)
    name = args.first
    raise CommandError, 'dump requires a VM name' unless name
    vm = vm_for(name)            # raises CommandError for an unknown VM
    out, err, = executor.capture_unchecked(vm.dump_command)
    if out.strip.empty?
      detail = err.strip.empty? ? '' : ": #{err.strip}"
      raise CommandError, "could not dump config for #{vm.name}#{detail}"
    end
    print out
  end
  ```
  **Important:** `config.dump=1` makes bhyve print the resolved config to
  **stdout** and **exit non-zero (status 1) by design**. So `dump` must NOT use
  the raising `executor.capture` (which treats any non-zero exit as failure and
  would discard the dump). Instead it uses `executor.capture_unchecked`
  (read-only; always executes, even under `-n`), which returns
  `[stdout, stderr, exitstatus]` without raising on a non-zero exit. Success is
  detected by **stdout being non-empty** (config.dump always produces output);
  an empty stdout means a genuine failure (e.g. bad template), surfaced as a
  `CommandError` carrying stderr.
- **CLI wiring** — add `require_relative 'commands/dump'`, register
  `'dump' => Commands::Dump` in `COMMANDS`, and add a usage line:
  `dump <name>            Print the VM's fully-resolved bhyve config (config.dump).`

## Error handling

- Missing name → `CommandError` ("dump requires a VM name") → CLI exit 1.
- Unknown VM → `CommandError` (via `vm_for`) → CLI exit 1.
- bhyve failure (e.g. bad template): no stdout produced → `CommandError`
  ("could not dump config …", carrying stderr) → CLI exit 1.
- Missing bhyve binary → `ExecutorError` ("command not found: bhyve") → exit 1.

## Testing

- **`VM#dump_command`** (unit): asserts `config.dump=1` appears immediately
  before the name; with a MAC set, asserts order is `… -o mac=<m> -o config.dump=1 <name>`.
- **`Commands::Dump`** (with `FakeExecutor`): canned capture output keyed on
  `config.dump=1`; asserts the captured command contains `-o config.dump=1` and
  the VM name, and that the output is printed; unknown-VM and missing-name raise
  `CommandError`.

## Out of scope (YAGNI)

- No generic `-o key=value` passthrough (a separate, larger surface).
- No `--start`-style flag overloading; `dump` is its own verb.
- No new output formatting — print bhyve's dump as-is.
