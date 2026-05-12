@ =============================================================================
@ powman.S - POWMAN password helper.
@
@ Datasheet ref: RP2350 sec 6.5.2.
@
@ POWMAN replaces RP2040's VREG_AND_CHIP_RESET on RP2350.  Every register
@ write must include the password 0x5afe in the upper 16 bits, otherwise
@ the write is silently dropped.  This helper centralises that pattern so
@ callers can't forget.
@
@ For the M2 milestone we don't actually touch VREG (the silicon's default
@ ~1.10 V is fine for 150 MHz; the RP2350 errata only require a bump to
@ 1.15 V for >= 200 MHz).  We still expose the helper so future M5/M6
@ work has a single place to change.
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ powman_unlock_write(reg_off, value)
@   r0 = byte offset within POWMAN
@   r1 = value (low 16 bits used; upper 16 bits replaced by 0x5afe)
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.powman_unlock_write, "ax"
    .thumb_func
    .global  powman_unlock_write
powman_unlock_write:
    movw    r2, #0xFFFF
    ands    r1, r2                          @ keep only low 16 bits
    movt    r1, #0x5AFE                     @ password in upper half

    ldr     r2, =POWMAN_BASE
    str     r1, [r2, r0]
    bx      lr
