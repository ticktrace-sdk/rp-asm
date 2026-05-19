# Bootloader

A layered, customer-flavorable boot chain for the RP2350. The stack:

```
Stage 0 (FSBL)  mask-ROM bootrom          Raspberry Pi; immutable.
                                          Reads IMAGE_DEF, sets SP/PC.
                                          We don't write this.

Stage 1 (SSBL)  ticktrace Second-Stage BL    src/ssbl/ssbl.S, < 4 KiB.
                                          At 0x10000000. Validates TSBL
                                          footer, hands off. Rarely
                                          re-flashed.

Stage 2 (TSBL)  flavored Third-Stage BL   src/tsbl/tsbl_<flavor>.S.
                                          At 0x10001000, up to 24 KiB.
                                          Owns app policy: A/B, DFU,
                                          signed boot, recovery.
                                          Field-updatable.

Stage 3 (App)   user firmware             link/app_at_0x10008000.ld.
                                          At 0x10008000.
```

The mask-ROM bootrom **cannot** be replaced. Anything below the FSBL boundary
(including the SSBL) is ticktrace code that the user controls. The SSBL is small
and stable on purpose: ship it once at factory, and only re-flash it for
SDK-level boot-format changes. Everything customer-specific lives in the TSBL.

## Memory map (Phase 1, single-slot `-bypass` flavor)

| Address       | Size       | Contents                              |
| ------------- | ---------- | ------------------------------------- |
| `0x10000000`  | 4 KiB      | SSBL: vectors, IMAGE_DEF, code        |
| `0x10001000`  | 24 KiB     | TSBL image (last 256 B = footer)      |
| `0x10006F00`  | 256 B      | TSBL footer (mkmanifest output)       |
| `0x10007000`  | 4 KiB      | reserved (Phase 2: A/B state)         |
| `0x10008000`  | 480 KiB    | App slot A (last 256 B = footer)      |
| `0x1007FF00`  | 256 B      | App slot A footer                     |
| `0x10080000`  | 480 KiB    | App slot B (Phase 2 -ab flavors only) |
| `0x100F7F00`  | 256 B      | App slot B footer                     |
| `0x10100000`  | 1 MiB      | user data partition (free)            |

Constants live in `include/bootloader.inc` (asm) and
`tools/internal/manifest/manifest.go` (host). Any change to the layout
requires both to be updated together; the tooling tests
(`tests/tools/test_mkfirmware_e2e.py`) lock the format in place.

## Slot footer (256 bytes)

The last 256 bytes of each slot. Built by `rpasm mkmanifest` from the slot's
payload `.bin`, appended to the slot by `rpasm mkfirmware`.

```
+0x00  magic        "RPBL"           u32 little-endian = 0x4C425052
+0x04  format_ver   1                u32
+0x08  payload_size                  u32  bytes covered by crc32 / digest
+0x0C  crc32                         u32  CRC-32-IEEE over payload[0..size)
+0x10  digest                        32 B  SHA-256 (Phase 1: present, unused
                                            by SSBL/TSBL; -signed uses it)
+0x30  signature                     64 B  ed25519 over (magic..digest);
                                            zero in unsigned builds
+0x70  seq                           u32  monotonic; -ab uses for slot pick
+0x74  status                        u32  empty/staged/trying/good/bad
+0x78  flavor_min                    u32  minimum TSBL flavor bitmap
+0x7C  reserved                      132 B
```

Status transitions are **bit-clear only** so a flashed footer can be promoted
(STAGED → TRYING → GOOD) in place without erasing the slot:

| Name    | Value         | Meaning                                 |
| ------- | ------------- | --------------------------------------- |
| EMPTY   | `0xFFFFFFFF`  | erased flash                            |
| STAGED  | `0xFFFFFFFE`  | written, not yet booted                 |
| TRYING  | `0xFFFFFFFC`  | booted once; awaiting `boot_confirm()`  |
| GOOD    | `0xFFFFFFF8`  | confirmed                               |
| BAD     | `0x00000000`  | failed verification or rollback         |

## SSBL boot path

```
_ssbl_reset:
  1. CPACR <- CP7 enable                  (same as src/startup.S)
  2. RCP canary seeding (idempotent)
  3. MSPLIM <- 0
  4. r0 = *(BL_TSBL_FOOTER + 0x00)        ; magic
     if r0 != "RPBL":   _ssbl_halt
  5. r1 = *(BL_TSBL_FOOTER + 0x08)        ; payload_size
     if r1 > 24 KiB - 256: _ssbl_halt     ; sanity bound
  6. expected = *(BL_TSBL_FOOTER + 0x0C)  ; CRC32
  7. computed = crc32_compute(BL_TSBL_BASE, payload_size)
     if computed != expected:  _ssbl_halt
  8. VTOR <- BL_TSBL_BASE
     MSP  <- *(BL_TSBL_BASE + 0x00)
     PC   <- *(BL_TSBL_BASE + 0x04)
```

CRC32 over 24 KiB at 150 MHz: ~13 ms. Acceptable boot delay; a table-driven
variant could be 5× faster but would consume most of the SSBL's 4 KiB
flash budget, not worth it for a once-per-boot operation.

The `_ssbl_halt` path is a `wfi` loop. Phase 2 will replace it with a
`watchdog_scratch[7] = 0xB001B005; soft_reset` sequence to drop back to
mask-ROM BOOTSEL, restoring a development-friendly recovery experience
when validation fails.

## TSBL flavors

The TSBL is the swappable, customer-pickable layer. Each flavor builds
into a 24 KiB image at `0x10001000`, all using `link/tsbl.ld` and all
implementing the same handoff pattern (validate-then-jump):

| Flavor              | Status     | Size (target) | What it adds                                              |
| ------------------- | ---------- | ------------- | --------------------------------------------------------- |
| `tsbl_bypass`       | Phase 1 ✓ | ~256 B        | validates slot A, jumps. Single slot, no DFU.            |
| `tsbl_ab`           | Phase 2 ✓ | ~512 B        | A/B selection by `seq` + scratch[6] rollback marker.     |
| `tsbl_dfu`          | Phase 3   | ~8 KiB        | USB CDC DFU on entry. Single slot.                        |
| `tsbl_ab_dfu`       | Phase 3   | ~10 KiB       | A/B + USB DFU + rollback.                                 |
| `tsbl_<x>_signed`   | Phase 4   | base + ~3 KiB | ed25519 verification with OTP-resident pubkey.            |
| `tsbl_<x>_recovery` | Phase 4   | base + ~1 KiB | minimal CDC console when both A and B fail to validate.   |

## A/B selection (`tsbl_ab`)

Reads both slot footers and picks one. Pure, table-driven, T1-tested:

```
scratch[6] = TRY_A:   A's previous attempt never confirmed -> boot B
                       (halts if B is invalid)
scratch[6] = TRY_B:   B's previous attempt never confirmed -> boot A
                       (halts if A is invalid)
scratch[6] = 0:       cold-boot or last attempt confirmed:
                       both valid:  pick higher .seq (ties favour A)
                       one valid:   pick it
                       neither:     halt
```

Before jumping, the TSBL writes `WATCHDOG_SCRATCH[6] = TRY_A` or `TRY_B`.
The booted app must call `boot_confirm()` (from `src/boot_api.S`) to clear
the marker. If the app crashes / hangs / never confirms before a warm
reset, the marker survives, and the TSBL boots the other slot. POR clears
scratch, so a clean power-cycle resets the rollback state.

This Phase 2 implementation is **read-only**: the TSBL never writes flash.
Persistent slot promotion (e.g. STAGED→GOOD after `boot_confirm`) requires
the app to call back into bootrom flash APIs and lands in Phase 3 alongside
DFU. As a result, Phase 2 cannot _permanently_ mark a slot BAD across power
cycles: a buggy slot with a high `seq` will be tried again on each cold
boot, fall back to the other slot, and repeat. That trade-off is acceptable
for v1: the rollback still recovers gracefully every time, and Phase 3
closes the loop.

### App-side API (`src/boot_api.S`)

```
boot_confirm()          clear WATCHDOG_SCRATCH[6]; call once main() is happy
boot_request_dfu()      WATCHDOG_SCRATCH[7] = FORCE_DFU; watchdog reset
boot_request_bootsel()  WATCHDOG_SCRATCH[7] = FORCE_BOOTSEL; watchdog reset
```

All three are AAPCS leaves. Link `src/boot_api.S` into an app if it needs
any of them; `tsbl_bypass` users don't have to.

### Building an A/B firmware image

```
make build/blinky_app.elf            # blinky linked at 0x10008000 (slot A)
make build/blinky_app_slotB.elf      # same blinky, linked at 0x10080000 (slot B)
make build/firmware_blinky_ab.uf2    # SSBL + TSBL-ab + both slots + footers
```

The combined UF2 places slot A at `seq=1` and slot B at `seq=2` by default,
so the TSBL boots slot B first. Override per-build:

```
make build/firmware_blinky_ab.uf2 TSBL_AB_SEQ_A=10 TSBL_AB_SEQ_B=3
```

### Demonstrating rollback on real silicon

A drag-droppable demo lives in the tree: no DFU, no buggy code to write:

```
make build/firmware_rollback_demo.uf2     # SSBL + TSBL-ab + two blinkies
```

Drop it on the BOOTSEL drive. The combined image flashes:

- Slot A (`seq=1`): `examples/blinky_confirmed_demo.S`, slow ~2 Hz
  blink, calls `boot_confirm()` early in main. Healthy.
- Slot B (`seq=2`): `examples/blinky_buggy_demo.S`, fast ~10 Hz blink,
  arms a 3-second watchdog, never feeds it, never confirms. Buggy.

Cold-boot timeline:

1. TSBL-ab picks slot B (higher seq), writes scratch[6] = TRY_B, jumps.
2. Slot B blinks fast for ~3 seconds.
3. Watchdog fires → warm reset (scratch survives POR but not power-off).
4. TSBL sees scratch == TRY_B, infers slot B failed, jumps to slot A.
5. Slot A calls `boot_confirm()`, scratch cleared, slow blink forever.

UART0 at 115200 8N1 (GP0 / pin 1) prints which slot is running:

```
ticktrace slot B (BUGGY, fast blink, no confirm) - will rollback in ~3s
ticktrace slot A (confirmed, ~2 Hz)
```

Pull USB and re-plug to repeat. (POR clears the watchdog scratch, so
each cold-boot gets a fresh "try B first" attempt.)

## Watchdog scratch ABI

The convention adopted from Van Hunter Adams' RP2040 design: the app writes
a magic to `WATCHDOG_SCRATCH[7]` and triggers a watchdog reset; the scratch
survives the warm reset, the SSBL/TSBL reads it on the way up.

| Value         | Constant                       | Meaning                            |
| ------------- | ------------------------------ | ---------------------------------- |
| `0x00000000`  | `BL_SCRATCH_NONE`              | normal boot                        |
| `0xB001DF00`  | `BL_SCRATCH_FORCE_DFU`         | TSBL enters DFU mode on this boot  |
| `0xB001B005`  | `BL_SCRATCH_FORCE_BOOTSEL`     | punt to mask-ROM BOOTSEL           |
| `0xB001A2A0`  | `BL_SCRATCH_PREFER_SLOT_A`     | (-ab) boot slot A this time        |
| `0xB001A2B0`  | `BL_SCRATCH_PREFER_SLOT_B`     | (-ab) boot slot B this time        |

The TSBL is responsible for clearing the scratch after consuming the request.

## Build

```
make tools                        # build tools/bin/rpasm (the Go CLI)
make bootloader                   # build/ssbl.bin + build/tsbl_bypass.bin
make build/blinky_app.elf         # blinky linked at 0x10008000
make build/firmware_blinky.uf2    # combined: SSBL + TSBL-bypass + blinky
```

Drag `build/firmware_blinky.uf2` onto the BOOTSEL drive on a Pico 2:
the mask-ROM bootrom programs each piece, then on the next boot:

```
FSBL  -> 0x10000000  -> SSBL._ssbl_reset
SSBL  -> CRC32(TSBL) OK -> jumps to 0x10001000
TSBL  -> CRC32(app)  OK -> jumps to 0x10008000
App   -> blinky runs
```

## Test

```
make test-tools     # 16 host-side tests (Go unit + Python parity + e2e)
make test-t1        # adds Unicorn-side asm tests (crc32, etc)
```

The on-chip CRC32 routine in `src/crc32.S` is exercised by
`tests/unicorn/test_crc32.py` against Python's `zlib.crc32` (which matches
Go's `hash/crc32.ChecksumIEEE`, which the mkmanifest tooling uses), pinning
all three implementations together; a divergence in any one is caught
before any firmware is shipped.

## References

The design draws from two existing custom-bootloader writeups:

- **Van Hunter Adams' Cornell ECE bootloader**:
  https://vanhunteradams.com/Pico/Bootloader/Bootloader.html
  The "first page last" power-fail safety pattern and the
  `WATCHDOG_SCRATCH`-based app→bootloader re-entry mechanism are adopted
  verbatim. Targets RP2040; we extend the same ideas to RP2350.
- **picoboot3 (IndoorCorgi)**:
  https://github.com/IndoorCorgi/picoboot3
  Selectable UART/I2C/SPI transports inform Phase 3's TSBL-DFU config
  knobs; the "Go to App" command opcode `0x40` will be the same for
  protocol-level compatibility.

Where ticktrace intentionally diverges: A/B slots (both references skip
them; we make `-ab` a first-class TSBL flavor) and signed boot (neither
reference does; we layer it via OTP-resident keys + ed25519 in `-signed`
flavors).
