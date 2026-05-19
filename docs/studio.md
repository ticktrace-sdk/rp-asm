# Studio

A sibling product to the ticktrace SDK that lets users pick a target, toggle
peripherals, build, and flash without touching `make` or `picotool`. Studio
lives in `studio/` as its own Go module and consumes the parent SDK by relative
paths: modules in the catalog point at `../src/foo.S`, linker scripts at
`../link/*.ld`. Nothing about Studio adds source code Studio doesn't already
consume; it is the build system from the user's perspective.

```
studio/
├── catalog/                     TOML descriptors for targets + modules
│   ├── targets/rp2350-arm.toml
│   ├── system/*.toml
│   └── peripherals/*.toml
├── cmd/
│   ├── rpasm/                   CLI binary
│   └── rpasm-studio/            Gio GUI binary
├── internal/
│   ├── build/                   as → ld → objcopy → UF2 / firmware UF2
│   ├── catalog/                 TOML loader
│   ├── flash/                   orchestrator: rpasmboot, drive copy, bootinfo
│   ├── project/                 .rpasm.toml loader + module resolver
│   ├── rpasmboot/               PICOBOOT v2 wire protocol
│   ├── uf2/                     UF2 reader
│   └── usbx/                    OS USB transport (usbfs on Linux)
└── testdata/*.rpasm.toml        sample project files
```

The CLI (`rpasm`) and GUI (`rpasm-studio`) share every internal package; the
two binaries differ only in their main file and the GUI's view layer. A
build that succeeds in one always succeeds the same way in the other.

## Project file (`*.rpasm.toml`)

Top-level fields:

| Field           | Type    | Required | Notes                                                            |
| --------------- | ------- | -------- | ---------------------------------------------------------------- |
| `name`          | string  | yes      | Identifier; drives output filenames (`<name>.uf2`)               |
| `target`        | string  | yes      | Must match a catalog target (`rp2350-arm` in v1)                 |
| `layout`        | string  | no       | `"flash"` (default) or `"sram"`                                  |
| `rpasm_version` | string  | yes      | Currently `"1.0"`                                                |
| `studio_mode`   | string  | no       | GUI hint: `"examples"` or `"custom"`. Inferred from contents.    |
| `example_name`  | string  | no       | GUI Examples-mode bookkeeping                                    |

Subtables:

```toml
[features]
UART = true
PIO  = false                   # explicitly override a catalog default

[user_source]
files = ["../src/main.S"]      # paths relative to SDK root

[bootloader]
tsbl = "ab"                    # "bypass" or "ab"; see docs/bootloader.md
```

`[features]` is a map of catalog symbol → bool. A `true` enables a module;
a `false` overrides a catalog default-on module off. Symbols not listed take
their catalog default. The GUI's "Selected modules" badges show the resolved
set.

`[bootloader]`, when present, switches the build engine into chain mode:
the app links at slot A's base (`0x10008000`), SSBL and the chosen TSBL flavor
are assembled from the SDK, footers are computed, and the chain is packed into
`firmware_<name>.uf2`. `[bootloader]` requires `layout = "flash"`.

## Catalog (`studio/catalog/`)

### Target TOML

`catalog/targets/<name>.toml`:

| Field             | Type      | Notes                                                  |
| ----------------- | --------- | ------------------------------------------------------ |
| `name`            | string    | Matches the project's `target` field                   |
| `arch`            | string    | `"arm"` (Hazard3 RISC-V deferred to v1.1)              |
| `toolchain_prefix`| string    | e.g. `"arm-none-eabi-"`                                |
| `as_flags`        | []string  | Pass-through to `as`                                   |
| `as_includes`     | []string  | Each becomes `-I <path>`                               |
| `ld_flags`        | []string  | Pass-through to `ld`                                   |
| `ld_script_flash` | string    | Linker for `layout = "flash"`                          |
| `ld_script_sram`  | string    | Linker for `layout = "sram"`                           |
| `flash_load_addr` | u32       | UF2 block base when layout=flash                       |
| `sram_load_addr`  | u32       | UF2 block base when layout=sram                        |
| `uf2_family_id`   | u32       | Default family ID; UF2 family is also auto-picked by load address (`0xE48BFF57` for SRAM-range addresses) |

### Module TOML

`catalog/{system,peripherals}/<name>.toml`:

| Field         | Type      | Notes                                                  |
| ------------- | --------- | ------------------------------------------------------ |
| `symbol`      | string    | Stable identifier referenced from `[features]`         |
| `name`        | string    | Human label for the GUI checkbox                       |
| `category`    | string    | `"system"` or `"peripherals"`                          |
| `order`       | int       | Link-time ordering; ties broken by symbol              |
| `default`     | bool      | Enabled when no `[features]` entry overrides it        |
| `description` | string    | Shown as hover/help in the GUI (planned)               |
| `sources`     | []string  | `.S` files included when the module is enabled         |
| `requires`    | []string  | Other symbols that must also be enabled                |

Path conventions: `sources` use relative paths from the SDK root
(`../src/uart.S`). The build engine's working directory is the SDK root, so
`.include "src/uart.S"` directives inside an `.S` file resolve naturally.

## Build pipeline

![Studio build pipeline](../book/figures/studio-build-pipeline.svg)

### Slot-only mode

`build.Options.Slot = "a" | "b"` (CLI `--slot a|b`) builds **just the app at
that slot's base** and packs only `app + app-footer`:

| Slot | Linker script                         | App base       | Footer addr    | Default seq |
| ---- | ------------------------------------- | -------------- | -------------- | ----------- |
| A    | `link/app_at_0x10008000.ld`           | `0x10008000`   | `0x1007FF00`   | 1           |
| B    | `link/app_at_0x10080000.ld`           | `0x10080000`   | `0x100F7F00`   | 2           |

Output filename: `slot_<a|b>_<name>.uf2`. SSBL/TSBL are not rebuilt or written;
the existing on-chip bootloader chain selects between A and B by sequence.

### Output files

A bootloader project produces, in `studio/build/<name>/`:

| File                        | Contents                                            |
| --------------------------- | --------------------------------------------------- |
| `<name>.elf`, `.bin`, `.map`| App build at slot A's base                          |
| `firmware_<name>.uf2`       | Full chain: SSBL + TSBL + footers + app + footer    |
| `slot_a_<name>.uf2`         | Slot-A-only (after `--slot a`)                      |
| `slot_b_<name>.uf2`         | Slot-B-only (after `--slot b`)                      |
| `_ssbl/`, `_tsbl_<flavor>/` | Per-stage intermediates (object, ELF, bin, map)     |

Non-bootloader projects produce just `<name>.{elf,bin,map,uf2}`.

## Flash pipeline

### rpasmboot (PICOBOOT v2)

The in-tree client (`studio/internal/rpasmboot`) speaks the RP2350 PICOBOOT
wire protocol directly over `usbfs` on Linux. No external `picotool` or
`libusb` dependency.

| Command            | ID   | Used for                                      |
| ------------------ | ---- | --------------------------------------------- |
| `EXCLUSIVE_ACCESS` | 0x01 | Lock the USB MSC interface (eject the drive) |
| `FLASH_ERASE`      | 0x03 | Sector-aligned erase                          |
| `WRITE`            | 0x05 | Page-aligned write (flash or SRAM)            |
| `EXIT_XIP`         | 0x06 | Required before any flash read/write          |
| `READ`             | 0x84 | Read flash/SRAM (IN direction)                |
| `REBOOT2`          | 0x0a | Reboot into Normal / RAM_IMAGE / BOOTSEL      |
| `GET_INFO`         | 0x8b | Chip info                                     |

Two gotchas worth noting (see `MEMORY.md → PICOBOOT protocol gotchas`):

1. PICOBOOT interface on shipped silicon has `bInterfaceProtocol=0x00`, not
   `0x01` as `RESET_INTERFACE_PROTOCOL` in the SDK header suggests. The
   enumerator filters on `bInterfaceClass=0xff` only.
2. Control transfers (`IF_RESET`, `IF_CMD_STATUS`) use `bmRequestType` of
   **vendor** type (`0x41` / `0xc1`), not class (`0x21` / `0xa1`).

### Method selection

`flash.Options.Prefer`:

| Value         | Behavior                                                                 |
| ------------- | ------------------------------------------------------------------------ |
| `""` (auto)   | rpasmboot first; on failure, fall back to drive copy                     |
| `rpasmboot`   | Force rpasmboot                                                          |
| `drive`       | Force drive copy (write the UF2 onto the mounted RPI-RP2 / RP2350 drive) |

CLI: `rpasm flash --method rpasmboot|drive|auto`.

### Orchestrator phases (rpasmboot path)

1. `usbx.Open` finds the BOOTSEL device.
2. `IF_RESET` clears any stale stalled state from a prior session.
3. `EXCLUSIVE_ACCESS` (with EJECT) takes ownership and unmounts the MSC drive.
4. `EXIT_XIP` if any flash range is present.
5. For each flash range: erase widened to sector boundaries, then write in
   4 KiB chunks (page-aligned, padded with `0xFF`).
6. For each SRAM range: direct write, no erase, no alignment requirement.
7. `REBOOT2`:
   - `Normal` if any flash range was written.
   - `RAM_IMAGE` (base = lowest SRAM addr, size = span) if SRAM-only.

A transport error on the `REBOOT2` ACK is expected and logged at info; the
device disappears mid-transfer.

## CLI reference (`rpasm`)

```
rpasm validate [--root DIR] <project.toml>
rpasm build    [--root DIR] [--out DIR] [-v] [--slot a|b] <project.toml>
rpasm flash    [--method rpasmboot|drive] [--slot a|b]
               (--uf2 <path> | [--root DIR] <project.toml>)
rpasm reboot   [--bootsel]
rpasm info
rpasm bootinfo
rpasm doctor   [--root DIR]
```

| Subcommand | Purpose                                                               |
| ---------- | --------------------------------------------------------------------- |
| `validate` | Load project + catalog, print resolved modules and source list       |
| `build`    | Produce the UF2 (or firmware UF2)                                     |
| `flash`    | Write a UF2 to a BOOTSEL'd board                                      |
| `reboot`   | REBOOT2 the device (`--bootsel` enters BOOTSEL instead of Normal)    |
| `info`     | Enumerate BOOTSEL devices over USB (VID/PID/serial)                  |
| `bootinfo` | Read both slot footers from a BOOTSEL'd board (status/seq/CRC)       |
| `doctor`   | Toolchain detection + udev rule status + board status                |

## GUI map (`rpasm-studio`)

```
┌─ Mode tab bar:   Examples │ Custom Project ────────────┐
├─ Top bar:        Title │ Target │ Layout │ Build · Flash
├─ Tools row:      udev OK · Board status · Query slots
│                   └─ slot panel (after Query slots) ──
├─ Project row:    [path input] · Browse... · Save · Load
│
├─ Left pane:      Examples mode → example preview
│                  Custom mode  → Source input + selected
│                                 modules + Features grid
└─ Right pane:     Output │ Problems │ Memory ─────────
                   └ Memory tab: Regions · Bootloader
                                 chain · Sections
```

### Modes

- **Examples**: Pick from `examples/*.S` + the canonical `src/main.S` blinky.
  Layout defaults to `sram`. No `[features]` UI; uses catalog defaults.
- **Custom Project**: Pick `[features]` + a `.S` file path. Layout defaults
  to `flash`. Browse... + Load round-trips a `.rpasm.toml` (including
  `[bootloader]`, silently carried through builds even though no widget
  toggles it yet).

### Tools row

- **udev**: Linux only. Shows whether `/etc/udev/rules.d/99-rpasmboot.rules`
  is installed. `rpasm doctor` prints the one-line `sudo` install command.
- **Board**: Polled every 2 s via `flash.DetectBoard` (which scans
  `/proc/mounts` for the RPI-RP2 / RP2350 drive label).
- **Query slots**: Runs `flash.ReadBootInfo` against the connected device.
  Renders a per-slot panel below the row.

### Memory tab

Three sections, populated after each successful build:

- **Regions**: `ld --print-memory-usage` output (FLASH / SRAM).
- **Bootloader chain** (bootloader projects only): per-stage used/capacity
  (SSBL, TSBL-`<flavor>`, Slot A, Slot B) with base addresses.
- **Sections**: `arm-none-eabi-size -A` output.

The same content is mirrored to stderr after each build (the GUI's `a.log`
helper writes to both the Output panel and the launching terminal).

## Host setup

### Linux USB access

PICOBOOT needs udev rule for non-root access. `rpasm doctor` checks
`/etc/udev/rules.d/99-rpasmboot.rules`; if missing, it prints the install
command. The rule body is:

```
SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0666", TAG+="uaccess"
```

`MODE=0666` is the fallback; `TAG+="uaccess"` grants the logged-in user via
logind ACLs where present.

### Toolchain

`rpasm doctor` checks for `arm-none-eabi-{as,ld,objcopy,size}` (prefix from
target TOML's `toolchain_prefix`). Missing tools fail at build time with a
diagnostic; the toolchain is **not** bundled with Studio.

### Workspace

The repo uses a `go.work` file bridging `studio/` and `tools/` so Studio
imports `tools/manifest` + `tools/firmware` (the bootloader footer + chain
packers shared with the parent Makefile build). Building either module
from the workspace works; building outside it requires a `replace`
directive.

## Cross-references

- Bootloader chain semantics, footer format, slot state machine, watchdog
  scratch ABI: [`docs/bootloader.md`](bootloader.md).
- Parent SDK Makefile-driven build (alternative to Studio):
  `make build/<name>.uf2`, `make bootloader`, `make build/firmware_<name>.uf2`.
- Per-peripheral module references: `docs/{adc,uart,usb,pio,...}.md`.
