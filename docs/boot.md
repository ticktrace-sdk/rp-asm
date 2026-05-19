# Boot - bootrom -> `_reset` -> `main`

This document covers the early-boot path in `src/startup.S` and the
two linker layouts in `link/`.  If you're chasing a new bring-up
failure, the [Debugging boot hangs](#debugging-boot-hangs) section at
the bottom is the entry point.

Datasheet references: RP2350 datasheet rev 0.3 (Aug 2024) sec 5 (Boot),
sec 3.2 (Interrupts), sec 7.5 (RESETS).  ARMv8-M Architecture Reference
Manual sec B11 (VTOR, MSPLIM).

## The two build paths

| Path | Linker | Load address | UF2 family | Use for |
| ---- | ------ | ------------ | ---------- | ------- |
| SRAM-resident  | `link/sram.ld`  | `0x20000000`     | `0xE48BFF57` (RP2XXX_ABSOLUTE) | T1/T2/T3 tests, fast iteration in emulators, also works on hardware |
| Flash-resident | `link/flash.ld` | `0x10000000` XIP | `0xE48BFF59` (RP2350_ARM_S)    | Persistent firmware on hardware |

Both paths share `src/startup.S`, `_vectors`, the IMAGE_DEF block, and
the same `_reset` prologue.  Only the load address and the UF2 family
ID differ.  The in-tree `rpasm` packer picks the family ID
automatically from the load address.

The default `make build/<name>.uf2` produces an **SRAM** image.  For
firmware that survives a power cycle, build `make build/<name>_flash.uf2`.

### A note on UF2 family IDs (and a previous bug)

Older versions of `tools/uf2.py` hard-coded family ID `0xE48BFF59`
(RP2350_ARM_S) for both SRAM and flash images.  That mismatch caused
SRAM-resident UF2s to be silently rejected by the bootrom on real
hardware: the BOOTSEL drive would eject normally, but the core never
actually entered the loaded image, leaving the board apparently dead.
The pico-sdk's `src/rp2_common/pico_crt0/rp2350/memmap_no_flash.ld`
demonstrates the working pattern, and picotool's `elf2uf2` selects
the family by inspecting the ELF segment addresses (RAM range vs flash
range).  ticktrace now does the same; see `family_for()` in
`tools/uf2.py`.

If you're hunting a "drive ejects, board does nothing" symptom, the
first thing to check is the UF2 header's `family_id` field at offset
`+0x1c` of the first 512-byte block.  It must match the load address.

## Post-bootrom state

The bootrom hands off with most peripherals in some default state
that the SDK has to clean up.  In particular:

- **MSP** is set to vec[0] of the image (= `_stack_top`).
- **VTOR** points wherever the bootrom left it; we re-point it.
- **MSPLIM** may be set high enough to fault on the first `push`.
- **CPACR** has the RCP coprocessor (CP7) possibly enabled, possibly
  not; instructions targeting CP7 fault if it's disabled.
- **RCP canary seeds** may or may not have been initialised; double-
  initialising them is itself a fault.
- **`clk_peri` is off**, so peripherals with their own clock domain
  (UART, I2C, SPI, ...) cannot assert `RESET_DONE` until later.
- **`io_bank0` and `pads_bank0` are already out of reset** -- we
  re-release them to be defensive but they'd be usable anyway.
- USB is out of reset on some firmware paths but not all; the USB
  driver assumes it isn't.

## `_reset` prologue

```
_reset:
    1. CPACR <- enable CP7 (RCP) full access
    2. mrc p7, #1, ...    -> RCP canary status; skip step 3 if seeded
    3. mcrr p7, ...       -> seed RCP canaries
    4. MSPLIM <- 0
    5. Copy _vectors (272 B) -> _ram_vectors  (in .bss, 512-aligned)
    6. VTOR <- _ram_vectors
    7. RESETS_RESET CLR <- (1<<6) | (1<<9)   ; io_bank0 + pads_bank0
    8. spin until RESETS_RESET_DONE has both bits set
    9. b main
```

Each step exists because removing it breaks something on real silicon:

- **CPACR / RCP seeding** mirrors pico-sdk's crt0.S `_entry_point` for
  NO_FLASH builds.  If RCP is left in an inconsistent state the next
  RCP-protected access faults.  Idempotent on every path.
- **MSPLIM = 0** because the bootrom may have left it high enough
  that the *first* `push {r4, r5, lr}` in any AAPCS function (e.g.
  `pll_init` or `blink_n`) trips STKOF -> HardFault -> `_halt`.
- **Vector relocation to SRAM** because for flash-resident images the
  vector table lives at XIP 0x10000000 (read-only); `nvic_install_handler`
  patches a vector entry by writing to `VTOR + (16+irq)*4`, which is a
  silent no-op against flash.  Copying the table to SRAM and pointing
  VTOR at the copy makes dynamic IRQ wiring work on both build paths.
- **RESETS mask is io_bank0 + pads_bank0 only.**  The original mask
  also included `uart0` (bit 26), but UART0 needs `clk_peri` running
  before its `RESET_DONE` bit asserts -- and `clk_peri` is off until
  `clocks_init` runs.  The spin loop hung forever waiting for that
  bit.  `uart0_init` releases UART0 itself, after `clocks_init`, by
  the same RESETS-CLR + spin pattern.  Any other peripheral with its
  own clock (I2C, SPI, USB, ...) follows the same rule: release in
  its own `_init`, not in `_reset`.

The exact sequence is bisectable via `examples/diag_*.S` if you need
to investigate a future failure -- see below.

## Vector table

```
0x000  _stack_top                    ; SP loaded by bootrom from here
0x004  _reset + 1                    ; PC loaded by bootrom from here
0x008  NMI handler                   ; -> _halt
...
0x03C  SysTick handler               ; -> _halt   (16 core vectors fill 0x00..0x40)
0x040  external IRQ 0  (TIMER0_IRQ_0)
0x044  external IRQ 1  (TIMER0_IRQ_1)
...
0x0F8  external IRQ 46 (SPARE_IRQ_0)
0x10C  external IRQ 51 (SPARE_IRQ_5)
0x110  end of table (= 16 core + 52 external = 68 entries * 4 = 272 B)
```

All 52 RP2350 external IRQ slots default to `_halt + 1`, so a stray
IRQ parks the core in `wfi` instead of executing garbage.  Wire a real
handler with:

```asm
movs    r0, #USBCTRL_IRQ            @ from include/usb.inc (= 14)
ldr     r1, =my_usb_isr
bl      nvic_install_handler        @ patches _ram_vectors[16 + irq]
movs    r0, #USBCTRL_IRQ
bl      nvic_enable_irq             @ sets NVIC ISER bit
```

`nvic_install_handler` is in `src/nvic.S` and reads VTOR to find the
table, so it works for both build paths.

### IMAGE_DEF placement

The linker scripts park the IMAGE_DEF block at offset `0x180` from
the image start (after the 272-byte vector table).  The bootrom scans
the first 4 KiB for the picobin marker (`0xFFFFDED3`), so 0x180 is
safe with room to spare.  The block itself is the 5-word minimum:

```
.word 0xFFFFDED3                                   ; marker_start
.word 0x42 | (1 << 8) | (0x1021 << 16)             ; IMAGE_TYPE item
.word 0xFF | (1 << 8)                              ; LAST item
.word 0                                             ; next_block_offset
.word 0xAB123579                                   ; marker_end
```

`0x1021` = EXE | Secure | ARM | RP2350.

## Linker scripts

`link/sram.ld` and `link/flash.ld` are nearly identical:

```
MEMORY:    sram.ld -> SRAM at 0x20000000
           flash.ld -> FLASH at 0x10000000 + SRAM at 0x20000000

.text  :   sram.ld -> SRAM
           flash.ld -> FLASH
           Both: KEEP(.vectors), pad to 0x180, KEEP(.image_def),
                 .text._reset, .text.main, .text*, .rodata*

.data  :   sram.ld -> SRAM (LMA == VMA)
           flash.ld -> SRAM (VMA), AT > FLASH (LMA)
           Currently empty in the SDK; the LMA-in-flash hookup is
           ready for when it isn't.

.bss   :   SRAM, NOLOAD.  Contains _ram_vectors.

_stack_top = end of SRAM - 4.
```

If `.data` ever grows non-empty in the flash-resident build, `_reset`
will need a copy-from-LMA-to-VMA loop before `b main`.

## UF2 generation

The in-tree packer lives in `tools/cmd/rpasm/uf2.go` (Go) with a
parity-tested legacy implementation at `tools/uf2.py`. Picotool's
output is byte-identical for our images (verified by
`tests/tools/test_uf2_parity.py`), so we keep the in-tree tool to
avoid the external dependency. The family ID is `0xE48BFF59`
(rp2350-arm-s) for flash and `0xE48BFF57` (rp2xxx-absolute) for SRAM
images, matching what picotool's `elf2uf2` picks based on load
address.

The Makefile load-address knob:

```
make build/blinky.uf2          # LOAD_ADDR = 0x20000000 (SRAM)
make build/blinky_flash.uf2    # FLASH_LOAD_ADDR = 0x10000000 (XIP)
```

Picotool's `--abs-block` RP2350-E10 workaround does **not** apply to
RAM binaries (picotool skips it), and the flash path doesn't appear to
need it either based on our testing.  If a future board hits E10
symptoms (image silently rejected after the drive ejects), adding
abs-block emission to `rpasm uf2 pack` is the workaround.

## Debugging boot hangs

If a flash UF2 ejects the drive but the LED never blinks:

1.  **Flash `examples/diag.S` (as `diag_flash.uf2`)**.  It runs the same
    bring-up sequence as `src/main.S` but blinks N times between each
    call.  Stop counts tell you the last stage that succeeded.
2.  **If diag also dies before stage 1**, the failure is in `_reset`
    itself.  Build a single-file minimal image (no driver objects, its
    own `_vectors` + `_image_def` + `_reset`) and add `_reset` steps
    one at a time -- this is how the original M2 hang was found.
    Look at `git log --grep "Fix RP2350 hardware bring-up"` for the
    commit that landed the current prologue; commits leading up to it
    document each bisect step.

Things that have caused real-silicon-only hangs in the past, all now
guarded by `_reset` or driver code:

- Releasing UART0 in `_reset` before `clk_peri` is up.
- Missing MSPLIM zero before the first `push`.
- Trying to `nvic_install_handler` on a flash-resident vector table.
- Forgetting `INTERRUPT_PER_BUFF` on a USB EP control word.

See also: [calling.md](calling.md) for the AAPCS contract every
`_init` follows; [clocks.md](clocks.md) for what `clocks_init` does
to `clk_peri` (which is why peripheral resets defer to `_init`); and
[usb.md](usb.md) for the worked example of how all this composes.
