# PCI Passthrough (GPU-first) — Design

Date: 2026-08-31
Status: approved

## Goal

Pass host PCI devices — primarily an NVIDIA GPU (5070 Ti class) — into a
bhyve guest so a Linux VM can run CUDA workloads (OpenWebUI/Ollama).
Headless compute only: no guest display output from the card, no ROM
files; the console stays VNC/serial.

## Scope decision: validate-only host integration

vmctl does **not** manage host-side device reservation. The admin binds
the device to the `ppt` driver once via `pptdevs="..."` in
`/boot/loader.conf` and reboots. vmctl's `start` preflights that the
host is actually ready and fails with an actionable message otherwise —
the same philosophy as netgraph bridges (vmctl uses them, doesn't
create the underlying config) and system files are never edited.

## Inventory schema

New per-VM field `passthru:` — a list of host device addresses in
`bus/slot/func` form, matching `pciconf -l` selector order:

```yaml
vms:
  openwebui:
    passthru:
      - "2/0/0"
```

- `Config#parse_passthru` validates each entry against `^\d+/\d+/\d+$`
  (ConfigError otherwise) and rejects duplicate addresses within a VM.
- `VMEntry` gains a `:passthru` member, defaulting to `[]`.
- `vm_to_h` emits `passthru` only when non-empty (round-trips through
  save/load like every other field).
- **No `defaults:`-level field** — a PCI device can only attach to one
  VM, so a shared default would be a lie.

## Rendering

A new `passthru_keys` generator appended to `ConfigRenderer#generators`:

- Device *i* lands at guest bus 0, slot `10 + i` (slots 10–13, hard cap
  of 4 devices). This is clear of the existing slot map: 3 = disks,
  4 = NICs, 5 = installer ISO, 6 = cloud-init seed, 7 = fbuf, 8 = xhci.
- Emits `pci.0.<slot>.0.device=passthru` plus the device-address key.
- Emits `memory.wired=true` whenever the list is non-empty — bhyve
  requires wired guest memory for passthrough, so it is implied rather
  than requiring `memory_wired: true` separately. (An explicit
  `memory_wired: true` remains harmless.)

**Implementation-time verification:** the exact bhyve_config(5) key for
the device address must be confirmed on monibeast before coding —
candidates are `pci.0.<slot>.0.path=2/0/0` vs. separate
`bus=`/`slot=`/`func=` keys. The command-line equivalent is
`-s 10,passthru,2/0/0`.

## CLI verbs

Modeled directly on add-disk/remove-disk:

- `vmctl add-passthru <vm> <bus/slot/func>` — validates the address
  format, rejects duplicates, enforces the 4-device cap, appends to the
  entry, saves the inventory, prints the "takes effect at next boot"
  note (`note_next_boot`).
- `vmctl remove-passthru <vm> <bus/slot/func>` — errors if the VM does
  not have that address; otherwise removes it and saves.
- Both registered in `cli.rb` dispatch and help text.
- `set` does not handle `passthru` (list-valued, same as disks and
  networks).

## Start preflight

In `Start#start_one`, when the VM has passthru devices: run `pciconf -l`
once through the executor and check each configured address. Hard
`CommandError` failures with the fix in the message:

- Address not present on the host:
  `no PCI device at 2/0/0 on this host (pciconf -l)`
- Present but bound to another driver (e.g. `nvidia0@pci0:2:0:0`):
  `2/0/0 is claimed by nvidia0, not ppt — add pptdevs="2/0/0" to
  /boot/loader.conf and reboot`

An unclaimed device (`none@...`) counts as not-ppt and gets the same
loader.conf guidance. Dry-run mode skips the check (start already
returns before host checks in dry-run).

`pciconf -l` line shape for parsing: `<driver><unit>@pci0:<bus>:<slot>:<func>:`
— a device is ready when the driver name is `ppt`.

## Display, dump, clone

- `info` shows the passthru list alongside the other hardware fields.
- `dump` picks the field up automatically via `vm_to_h`.
- `Clone#build_entry` sets `passthru: []` on the copy and warns:
  `passthru devices not copied (a PCI device can only attach to one VM)`.

## Testing

All against the stubbed executor, matching the existing suites:

- **Config**: parse valid list; reject bad formats and duplicates;
  round-trip through `to_h`/save/load; absent field yields `[]`.
- **Renderer**: slot assignment for 1 and 2 devices; implied
  `memory.wired=true`; no keys emitted when the list is empty.
- **Commands**: add-passthru happy path, duplicate error, cap error,
  bad-format error; remove-passthru happy path and not-found error.
- **Start preflight**: canned `pciconf -l` output for the ppt-bound
  (passes), other-driver, and missing-device cases.
- **Clone**: passthru dropped with a warning.

## README

A short "GPU/PCI passthrough" section covering:

- One-time host setup: find the address with `pciconf -lv`, add
  `pptdevs="<bus>/<slot>/<func>"` to `/boot/loader.conf`, reboot.
  Multi-function GPUs (GPU + HDMI audio) may list both functions;
  compute-only use needs just the GPU function.
- Recent NVIDIA cards (Blackwell/5070 Ti class) have large 64-bit BARs:
  host should run FreeBSD 14.x and the guest must boot UEFI (vmctl's
  default).
- Guest side: install the NVIDIA driver in the Linux guest; the GPU is
  compute-only and the console remains VNC/serial.

## Out of scope

- Editing loader.conf or running devctl (high blast radius; runtime
  GPU detach frequently wedges the host).
- ROM files / display output from the passed-through card.
- A host device discovery helper (`vmctl passthru list`) — deferred;
  the preflight error messages carry the needed guidance.
- Cross-VM conflict detection at config time (two entries claiming the
  same address). The kernel refuses the second `start`; a vmctl-level
  check can come later if it ever bites.
