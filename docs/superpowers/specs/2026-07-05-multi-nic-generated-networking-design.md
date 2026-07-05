# vmctl multi-NIC + generated networking — Design

**Date:** 2026-07-05
**Status:** Approved design, pre-implementation
**Builds on:** Phase 3 (dynamic configs + modify commands, PR #6) on `main`.

## Summary

Make networking inventory-driven, the same way disks became in Phase 3. vmctl
already generates disk devices (`pci.0.3.N`) from the inventory; this generates
**all** network devices (`pci.0.4.N`) too, and adds support for **multiple NICs**
per VM plus a **`none`** sentinel for a disconnected (network-less) VM.

Concretely:
- The primary NIC keeps its existing scalars (`network`/`link`/`mac`) — no
  inventory migration — plus a new optional `mtu` (default 9000).
- A new optional `networks:` list adds 0–7 **additional** NICs, each with
  `bridge` (required), `mtu` (default 9000), and `mac` (optional: literal or
  `generate`).
- `network: none` omits the primary NIC entirely (console-only VM).
- vmctl generates the `pci.0.4.*` block via a new `net_keys` generator (the
  `ConfigRenderer::GENERATORS` seam left for exactly this in PR #6), so the
  `pci.0.4.*` block is **removed from templates** (one-time edit, like disks).
- New `add-nic` / `remove-nic` commands and `set --mtu` / `set --network none`,
  mirroring the disk modify commands.

## Motivation

Today the primary NIC is template-owned (`pci.0.4.0` with `%(network)/%(link)/
%(mac)`), and there is no way to declare a second interface short of hand-writing
raw `options:` keys (choosing slots/peerhooks/sockets manually, with no bridge
validation). Multi-homed nodes are common; making NICs first-class from the
inventory removes that manual, error-prone surface and completes the "inventory
is the single source of truth" model.

## Networking model

`link` is a **VM-level** identity, not a per-NIC property: it names the console
device (`/dev/nmdm<link>`) *and* seeds the primary NIC's netgraph peerhook. So it
stays a top-level scalar, and the interface bound to it is **nic 0** (the
scalars). `networks:` describes **additional** interfaces. A VM has a primary NIC
unless `network: none`.

### Two independent concerns (this is what makes `none` clean)

1. **PCI function number** — assigned **sequentially over the NICs actually
   present**, so there is never a function-0 hole (a multifunction PCI device
   requires function 0, or the guest won't probe functions 1–7). Primary present:
   nic 0 → `pci.0.4.0`. `network: none` + one `networks:` entry: that entry →
   `pci.0.4.0`.
2. **peerhook / socket names** — **role-based, not slot-based**, so they stay
   unique and stable regardless of which function a NIC lands on:
   - primary → `peerhook=link<link>`, `socket=bhyve_<name>`
     (byte-identical to today's template output),
   - the *j*-th `networks:` entry (0-based) → `peerhook=link<link>_<j+1>`,
     `socket=bhyve_<name>_<j+1>`.

`link` is globally unique across VMs, so `link<link>` and `link<link>_<j>` never
collide across VMs, and the `_<j+1>` suffix disambiguates a single VM's NICs even
when two attach to the same bridge.

## Inventory schema

```yaml
vms:
  pod34:
    network: labs_vlan50      # primary NIC (nic 0); a bridge name, or `none`
    link: 10
    mac: 5a:9c:fc:00:00:11    # optional (as today)
    mtu: 9000                 # NEW, optional — primary NIC MTU (default 9000)
    networks:                 # NEW, optional — additional NICs (nic 1+)
      - { bridge: storage_vlan60, mtu: 9000, mac: 5a:9c:fc:00:00:20 }
      - { bridge: mgmt_vlan70 }        # mtu -> 9000; no mac -> bhyve auto-assigns
    disks:
      - { file: pod34-root.raw, size: 20G }

  isolated1:
    network: none             # console-only VM, no NICs
    link: 12
    disks:
      - { file: isolated1-root.raw, size: 20G }
```

### `Config` changes (`lib/vmctl/config.rb`)

- `VMEntry` gains `:mtu` and `:networks` members.
- New `Nic = Struct.new(:bridge, :mtu, :mac, keyword_init: true)`.
- `parse_vm` reads `mtu: body['mtu']` and `networks: parse_networks(body.fetch('networks', []))`.
- `parse_networks(list)` — validates a list of mappings, each with a non-empty
  `bridge`; builds `Nic`s. Raises `ConfigError` on a non-list, a non-mapping
  entry, or a missing bridge.
- `vm_to_h` emits `'mtu'` only when non-nil and `'networks'` only when non-empty
  (byte-stable for existing inventories). A `compact_nic` helper drops nil
  `mtu`/`mac` from each entry.

Values are stored **as authored** (nil when absent); the renderer applies the
9000 default. This keeps saved inventories minimal and byte-stable.

## Config generation

`ConfigRenderer`'s generator list becomes `[disk_keys, net_keys]` — `net_keys` is
appended to the existing seam; nothing else in the renderer changes.

### `net_keys(vm)` (`lib/vmctl/config_renderer.rb`)

Builds an ordered NIC list, then emits keys with sequential function numbers:

```ruby
def net_keys(vm)
  e = vm.entry
  nics = []
  unless e.network.nil? || e.network == 'none'
    nics << nic_spec(e.network, e.mtu, e.mac, "link#{e.link}", "bhyve_#{vm.name}")
  end
  (e.networks || []).each_with_index do |n, j|
    nics << nic_spec(n.bridge, n.mtu, n.mac,
                     "link#{e.link}_#{j + 1}", "bhyve_#{vm.name}_#{j + 1}")
  end
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
```

`device`/`backend` are fixed (`virtio-net`/`netgraph`). `mac` is emitted only
when present. Output is sorted by the renderer as usual, so a primary-only VM
produces exactly today's active `pci.0.4.0.*` key set (verified by test).

### MAC `generate`

Resolved to a concrete address **when the NIC is added** (by `add-nic`/`create`/
`set`) and stored literally — mirroring how `create --mac generate` works today.
The renderer only ever sees a literal MAC or nil; it does **not** resolve
`generate`. `Allocator#generate_mac` becomes index-aware:

```ruby
def generate_mac(name, index = 0)
  seed   = index.zero? ? name : "#{name}:nic#{index}"
  digest = Digest::SHA256.hexdigest(seed)
  # ... unchanged OUI + 3-byte tail ...
end
```

`generate_mac(name)` (index 0) stays byte-identical to today. Additional NICs are
resolved with a nonzero index so a VM's NICs never share a generated MAC.

## Validation

- **Bridges:** every NIC's bridge must exist. `VM#nic_bridges` returns the
  bridges to validate — the primary's (unless `none`/nil) plus each `networks:`
  bridge. `create` and `start` loop `Netgraph#ensure_bridge!` over
  `vm.nic_bridges` (replacing the current single `ensure_bridge!(entry.network)`
  call). `add-nic` validates the new bridge; `set --network <bridge>` validates
  the new primary bridge (skipped for `none`).
- **NIC cap:** at most **8** NICs total (`pci.0.4.0`–`pci.0.4.7`), where total =
  (primary present ? 1 : 0) + `networks.length`. Enforced in **one place** — a
  `VM#nic_count`/validation check used by `add-nic` (raises `CommandError` before
  appending a 9th) and by `create`/`start` (defensive for hand-edited
  inventories). `parse_networks` does **not** cap length (that would contradict
  the total: a `none`-primary VM may legitimately hold 8 in `networks:`); it only
  validates structure.
- **MAC format:** literal MACs are validated (`\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z`,
  case-insensitive) in `add-nic`/`set`, matching the existing MAC handling.

## Modify commands

Thin handlers extending `Commands::Base`, reusing `note_next_boot`, `Config#save`,
`Netgraph`, and `Allocator`. All edits warn "takes effect on next start" when the
VM is running; dry-run gates only `config.save`.

### `add-nic <vm> <bridge> [--mtu N] [--mac generate|<addr>]`

- Validates VM exists; total NIC count < 8; bridge exists (`ensure_bridge!`);
  `--mtu` parses as a positive integer if given; `--mac` is `generate` (→
  `Allocator#generate_mac(name, networks.length + 1)` — the 1-based position the
  new NIC will occupy — stored concrete) or a valid literal (omitted → nil).
- Appends a `Nic` to `entry.networks`; `config.save`; prints
  `added nic on <bridge> (pci.0.4.<f>) to <vm>` + next-boot note.

### `remove-nic <vm> <index>`

- `index` is the **1-based position in `networks:`** (additional NIC #1 =
  `networks[0]`); the primary NIC cannot be removed here (use
  `set --network none`), analogous to `remove-disk` refusing `root`.
- Validates the index is in range; deletes `entry.networks[index-1]`;
  `config.save`; prints what was removed + next-boot note. No `--purge` (NICs have
  no backing file).

### `set` additions (`lib/vmctl/commands/set.rb`)

- `--mtu N` → sets the **primary** NIC's `mtu` (`entry.mtu`).
- `--network none` → sets `entry.network = 'none'` and **skips** bridge
  validation; `--network <bridge>` validates as today. (`create --network none`
  likewise skips validation and is accepted despite `--network` being required.)

### CLI wiring (`lib/vmctl/cli.rb`)

`require_relative` the two new command files; register `'add-nic'`/`'remove-nic'`
in `COMMANDS`; add usage lines; add `--mtu`/`--network none` to the `set` help.

## Migration

- Remove the `pci.0.4.*` block (including the commented `#pci.0.4.0.mac=%(mac)`
  line) from the example flavors `pod.conf`, `pod-installer.conf`,
  `pod-cloudinit.conf`. vmctl generates it now.
- Existing single-NIC inventories need **no change** — their `network`/`link`/
  `mac` still drive nic 0, and `mtu` defaults to 9000 (matching the old hardcoded
  template value).
- Update the README: networking is generated at `pci.0.4.N` from `network` +
  `networks:`; templates must not declare `pci.0.4.*`; document `networks:`,
  per-NIC `mtu`/`mac`, and `network: none`.
- Pre-1.0, single-operator deployment: clean break, no auto-rewrite.

## Error handling

- Non-list `networks:`, a non-mapping entry, or a missing `bridge` →
  `ConfigError` at load → exit 1.
- Unknown VM / missing args / bad `--mtu` / bad `--mac` / 9th NIC / out-of-range
  `remove-nic` index / missing bridge → `CommandError` → exit 1. A hand-edited
  inventory exceeding 8 NICs fails the total-cap check at `create`/`start`.
- A NIC whose bridge is absent at `start`/`create` → `NetgraphError` → exit 1.

## Testing

- **`ConfigRenderer` net generation** (unit): primary-only renders exactly the
  legacy `pci.0.4.0.*` key set (regression guard); primary + 1 and + 7 additional
  NICs (function/peerhook/socket assignment); `network: none` shifts the first
  `networks:` entry to `pci.0.4.0` with role-based `link<link>_1`; `mtu` default
  vs override; `mac` literal present vs absent (no `.mac` key when nil); 8-NIC
  boundary.
- **`Allocator#generate_mac`**: `generate_mac(name)` unchanged; `generate_mac(name, 1)`
  differs and is a valid locally-administered MAC.
- **`Config`**: parse/round-trip of `mtu` + `networks` (+ `none`); absent stays
  absent; malformed `networks:` raises.
- **`VM#nic_bridges`**: primary + networks; excludes `none`/nil.
- **Commands** (FakeExecutor + temp inventory, round-tripped through
  `Config.load`): `add-nic` (append, bridge check, mtu/mac parse, `generate`
  stored concrete, 9th-NIC rejection, running note, dry-run no-persist);
  `remove-nic` (drops entry, index range, running note); `set --mtu`;
  `set --network none` (no bridge probe) and `create --network none`;
  multi-bridge validation in `create`/`start` (a missing second bridge fails).
- **Migration**: rendering a migrated example flavor + a two-NIC inventory
  produces a collision-free config.

## Out of scope (YAGNI)

- Device-type override (virtio-net vs e1000) — fixed to virtio-net.
- Per-additional-NIC `none` (additional NICs are simply omitted, not disconnected).
- Backends other than netgraph.
- Reordering NICs / changing the primary via `networks:` (primary is the scalars;
  use `set`).
- `add-nic`-style flags on `create` (create makes the primary; use `add-nic` for
  the rest).
- Auto-rewriting deployed templates.
