# vmctl graphics / VNC console — Design

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Builds on:** `main` (through CPU/memory inventory fields, PR #11).

## Summary

Add a per-VM `graphics: true/false` inventory field that generates a bhyve
`fbuf` (VNC framebuffer) console plus an `xhci` USB controller with an
absolute-position `tablet` pointer — a complete, usable graphical console. The
VNC TCP port derives from the VM's already-unique `link` (`vnc_base + link`), and
the socket binds to a host-wide `vnc_bind` address. Templates need no change; the
devices land on two currently-free PCI slots.

## Schema

- `VMEntry` gains `:graphics` (boolean; `nil`/absent treated as `false`).
- `Defaults` / `Config::DEFAULTS` gain two host-wide knobs (mirroring `link_base`):
  - `vnc_base` → **5900** — VNC port = `vnc_base + link`.
  - `vnc_bind` → **'0.0.0.0'** — address the VNC socket binds to.
- **Security note:** bhyve's `fbuf`/VNC console is **unauthenticated**. Default
  `vnc_bind` is `0.0.0.0` (reachable from any host that can route to the bhyve
  host). Operators who want loopback-only access set `defaults.vnc_bind:
  127.0.0.1` and tunnel (`ssh -L 5910:localhost:5910 host`). This tradeoff is
  documented in the README.

### `Config` changes (`lib/vmctl/config.rb`)

- `parse_defaults`: read `vnc_base` (via `Integer(...)`, positive) and `vnc_bind`
  (String) from merged defaults, falling back to `DEFAULTS`. Bad `vnc_base` →
  `ConfigError`.
- `parse_vm`: `graphics: parse_bool(body['graphics'])` — absent → `false`
  (follows the existing `autostart` boolean handling).
- `vm_to_h`: emit `'graphics' => true` **only when true** (existing inventories
  stay byte-stable; `false` is omitted).

## Generation

A new `graphics_keys(vm)` generator, appended to `ConfigRenderer`'s generator
list (after `hardware_keys`). Returns `{}` unless `vm.entry.graphics`. When
enabled it emits, on two free PCI slots (`pci.0.7`, `pci.0.8`):

```ruby
def graphics_keys(vm)
  return {} unless vm.entry.graphics
  {
    'pci.0.7.0.device'       => 'fbuf',
    'pci.0.7.0.tcp'          => vm.vnc_endpoint,   # "<vnc_bind>:<vnc_base+link>"
    'pci.0.7.0.w'            => '1024',
    'pci.0.7.0.h'            => '768',
    'pci.0.7.0.wait'         => 'false',
    'pci.0.8.0.device'       => 'xhci',
    'pci.0.8.0.slot.1.device' => 'tablet'
  }
end
```

- **Port** derives from `link` (`vnc_base + link`; link 10 → 5910). Always
  unique because `link` is already unique — no new allocator state.
- **Resolution** fixed at **1024×768**; **`wait=false`** (do not pause boot for a
  VNC client — correct default for a server). Both YAGNI-fixed for now.
- Generated keys run last, so they **win** over the flavor file and the
  `options:` map (same rule as disks/NICs/CDs/hardware).

### PCI slot map (after this change)

`0.0` hostbridge · `0.3.N` disks · `0.4.N` NICs · `0.5.0` installer CD ·
`0.6.0` cloud-init seed CD · **`0.7.0` fbuf** · **`0.8.0` xhci+tablet** ·
`0.20.0` rng · `0.31.0` lpc/console.

## VM helpers (`lib/vmctl/vm.rb`)

- `vnc_port` → `@defaults.vnc_base + entry.link` (Integer).
- `vnc_endpoint` → `"#{@defaults.vnc_bind}:#{vnc_port}"` (String), used by the
  generator and by `status`.

These are computed unconditionally (cheap); callers gate on `entry.graphics`.

## Status display

When a VM has `graphics: true`, `status` appends its VNC endpoint (e.g.
`vnc 0.0.0.0:5910`) so the operator knows where to connect. Shown only for
graphics-enabled VMs; non-graphics VMs are unchanged.

## CLI

- **`create --graphics`** — sets `entry.graphics = true` (omitted → false →
  defaults apply, i.e. no graphics device).
- **`set --graphics`** / **`set --no-graphics`** — toggles the field (boolean
  flag exactly like `--autostart`). Takes effect on next start (like other `set`
  edits; warns accordingly).

## Migration

None required.

- Two brand-new PCI slots (`0.7`, `0.8`) — no template edits, no collisions with
  existing generated devices.
- Existing inventories need no change — `graphics` defaults to `false`.
- README gains: the `graphics:` field, the `vnc_base`/`vnc_bind` defaults, the
  `port = vnc_base + link` rule, and the unauthenticated-console/bind caveat.

## Error handling

- `graphics` is a plain boolean — no validation beyond truthiness; no new failure
  modes at render time.
- Bad `defaults.vnc_base` (non-integer / ≤ 0) → `ConfigError` at load.

## Testing

- **`Config`**: `graphics` parse + round-trip; absent/false → not emitted; `true`
  → emitted. `defaults.vnc_base`/`vnc_bind` parse (custom + fallback to
  5900 / 0.0.0.0); bad `vnc_base` raises `ConfigError`.
- **`ConfigRenderer`**: no `graphics` / `graphics: false` → no `fbuf`/`xhci`
  keys; `graphics: true` → `fbuf` (tcp = `<bind>:<base+link>`, `w`/`h`/`wait`) +
  `xhci`/`tablet`; port tracks `link`; bind tracks `defaults.vnc_bind`; a
  conflicting `options:` `pci.0.7.0.*` loses to the generated keys.
- **`VM`**: `vnc_port` = `vnc_base + link`; `vnc_endpoint` = `"<bind>:<port>"`.
- **Commands**: `create --graphics` records the field; `set --graphics` /
  `set --no-graphics` toggle + round-trip; `status` shows `vnc <endpoint>` for a
  graphics VM and omits it otherwise.

## Out of scope (YAGNI)

- Per-VM resolution (`w`/`h` stay 1024×768).
- A `wait=true` toggle (always `false`).
- VNC password (`fbuf` `password=`) — bind-address is the only exposure control.
- VNC-port collision detection beyond `link` uniqueness.
- A structured `graphics: { … }` map form — the field is a plain boolean.
