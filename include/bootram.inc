@ =============================================================================
@ bootram.inc - BOOTRAM region constants.
@
@ The BOOTRAM is a 1 KiB SRAM block (separate from the four 64 KiB main
@ SRAM banks) used by the bootrom for its scratch state during boot.
@ Not all of it is application-free; the layout (per RP2350 datasheet
@ + pico-sdk crt0/flash/bootrom sources) is:
@
@   0x000..0x0FF  bootrom-owned: boot2 / XIP setup stub (256 B).  Required
@                 to re-enable XIP after flash ops.  DO NOT touch.
@   0x100..0x2FF  application-free scratch (512 B).  Use this region.
@   0x300..0x37F  reserved for bootrom post-boot state (e.g. version
@                 downgrade erase address at 0x338, TBYB flag at 0x348).
@                 DO NOT touch.
@   0x380..0x3FF  application-free scratch (128 B).
@   0x800+        hardware regs (WRITE_ONCE, BOOTLOCK*, etc.) - not RAM.
@
@ The total RAM region (0x400E0000..0x400E0400 = 1 KiB) is followed by
@ the BOOTRAM hardware register block at 0x400E0800.
@
@ We define BOOTRAM_APP_BASE as the start of the first app-free chunk
@ so demos can stash scratch values without colliding with the bootrom.
@ =============================================================================

    .equ BOOTRAM_BASE,        0x400E0000
    .equ BOOTRAM_SIZE,        0x400        @ 1 KiB total
    .equ BOOTRAM_END,         0x400E0400

    .equ BOOTRAM_BOOT2_BASE,  0x400E0000   @ boot2 stub, 256 B (do not touch)
    .equ BOOTRAM_BOOT2_END,   0x400E0100

    .equ BOOTRAM_APP_BASE,    0x400E0100   @ start of app-free scratch
    .equ BOOTRAM_APP_END,     0x400E0300   @ end of first free chunk

    .equ BOOTRAM_BOOTROM_STATE_BASE, 0x400E0300   @ bootrom post-boot state
    .equ BOOTRAM_BOOTROM_STATE_END,  0x400E0380
