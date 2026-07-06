# vmctl stale-vmm detection — Design

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Builds on:** `main` (through cloud-init, PR #9).

## Summary

Surface the **stale vmm** state instead of misreporting it as running. Today
`VM#running?` is true iff `/dev/vmm/<name>` exists, so a bhyve that died
abnormally (its supervisor `kill -9`'d, so the `bhyvectl --destroy` cleanup never
ran) leaves a stale device and `status` shows a phantom "running" — and `start`
refuses with a misleading "already running".

Add a `VM#stale?` check (vmm device present but **no live supervisor**), give
`status` a third state (`running` / `stale` / `stopped`) with an actionable hint,
and make `start` report the stale case with the fix instead of "already running".

## Detection

Two new `VM` methods, both routed through the executor so they are testable with
`FakeExecutor` probes (consistent with `running?`):

```ruby
# A live supervisor = a pidfile whose pid is an existing process.
def supervisor_alive?(executor)
  pid = read_pid
  !!pid && executor.success?('kill', '-0', pid.to_s)
end

# vmm device exists but nothing is actually supervising it.
def stale?(executor)
  running?(executor) && !supervisor_alive?(executor)
end
```

`kill -0 <pid>` exits 0 when the process exists (root can always signal it), non-
zero otherwise — so `supervisor_alive?` is false when the pidfile is **missing**
(`read_pid` nil) *or* **stale** (dead pid). That covers both `kill -9` outcomes.

## `status` — third state (`lib/vmctl/commands/status.rb`)

The state resolves to one of three:

- **running** — `running?` && `supervisor_alive?` →
  `pod34: running pid 4242 (labs_vlan50 link 10)`
- **stale** — `running?` && !`supervisor_alive?` →
  `pod34: stale — vmm device with no live supervisor; run 'vmctl stop --force pod34' (labs_vlan50 link 10)`
- **stopped** — !`running?` → `pod34: stopped (labs_vlan50 link 10)`

The stale line **omits `pid N`** (the pidfile pid is dead/misleading) and shows
the fix hint instead. `running`/`stopped` output is unchanged. Determine the state
with a single `stale?`/`supervisor_alive?` evaluation to avoid probing twice.

## `start` — actionable stale error (`lib/vmctl/commands/start.rb`)

`start_one` currently does `raise CommandError, "#{vm.name} already running" if
vm.running?(executor)`. Replace with:

```ruby
if vm.running?(executor)
  if vm.stale?(executor)
    raise CommandError,
          "#{vm.name} has a stale vmm device — run 'vmctl stop --force #{vm.name}' first"
  end
  raise CommandError, "#{vm.name} already running"
end
```

So a genuinely-running VM still gets "already running"; a stale device gets the
fix. (The dry-run branch above is unchanged.)

## Error handling

`supervisor_alive?` never raises: `executor.success?` swallows spawn failures to
`false` (a missing `kill` binary or unrunnable command → treated as "not alive"),
and `read_pid` already returns `nil` on a missing/garbled pidfile.

## Testing

- **`VM#supervisor_alive?` / `stale?`** (FakeExecutor probes): live (`'/dev/vmm/pod34' => true`,
  `'kill -0 4242' => true`) → not stale; dead pid (`kill -0` false) → stale; no
  pidfile (no `.pid` file) → stale; no vmm device (`/dev/vmm` false) → not stale
  (stopped).
- **`status`** output for all three states (running with pid, stale with hint + no
  pid, stopped).
- **`start`** raises the stale-device error (with the `stop --force` hint) for a
  stale VM, and still raises plain "already running" for a live one; the
  bridge/write/launch path is unaffected when not running.

## Out of scope (YAGNI)

- Auto-recovery (having `status`/`start` destroy the stale device themselves) —
  keep it advisory; the operator runs `stop --force`.
- Cleaning up the stale pidfile as a side effect — `stop --force` remains the
  remedy; a separate pidfile tidy is not added here.
- Changing `running?`'s definition — it stays "vmm device exists"; `stale?`
  layers the liveness check on top.
