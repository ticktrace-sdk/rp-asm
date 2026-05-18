@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ tsbl_bypass.S - The minimal "get out of my way" TSBL flavor.
@
@ Validates the app in slot A and jumps. No DFU, no A/B, no signing. Drop-in
@ replacement for users who want the SDK's bootloader chain without paying
@ for the policy machinery they don't need. Other TSBL flavors (ab, dfu,
@ signed, recovery) will live alongside this one as separate binaries
@ flashed into the same 24 KiB TSBL slot.
@
@ Shape mirrors the SSBL almost exactly: vector table + IMAGE_DEF + _reset
@ that validates the next stage's footer and hands off. The only differences
@ are the addresses (app slot A footer / payload instead of TSBL footer /
@ payload) and the entry-point name (so we can build both into the same
@ test image without symbol collision).
@ =============================================================================

    .include "rp2350.inc"
    .include "bootloader.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ TSBL vector table at 0x10001000.
@ ----------------------------------------------------------------------------
    .section .tsbl_vectors, "ax"
    .align   2
    .global  _tsbl_vectors
_tsbl_vectors:
    .word _stack_top
    .word _tsbl_reset + 1
    .word _tsbl_halt  + 1       @ NMI
    .word _tsbl_halt  + 1       @ HardFault
    .word _tsbl_halt  + 1       @ MemManage
    .word _tsbl_halt  + 1       @ BusFault
    .word _tsbl_halt  + 1       @ UsageFault
    .word _tsbl_halt  + 1       @ SecureFault
    .word 0
    .word 0
    .word 0
    .word _tsbl_halt  + 1       @ SVCall
    .word _tsbl_halt  + 1       @ DebugMon
    .word 0
    .word _tsbl_halt  + 1       @ PendSV
    .word _tsbl_halt  + 1       @ SysTick

@ ----------------------------------------------------------------------------
@ IMAGE_DEF at +0x180 - not strictly required (the FSBL never sees the
@ TSBL directly), but keeping it means picotool info / OTA tooling can
@ inspect the TSBL as a stand-alone image.
@ ----------------------------------------------------------------------------
    .equ TSBL_IMG_FLAGS, 0x1021

    .section .tsbl_image_def, "a"
    .align   2
    .global  _tsbl_image_def
_tsbl_image_def:
    .word 0xffffded3
    .word 0x42 | (1 << 8) | (TSBL_IMG_FLAGS << 16)
    .word 0xff | (1 << 8)
    .word 0
    .word 0xab123579

@ ----------------------------------------------------------------------------
@ _tsbl_reset - validate slot A, hand off.
@
@ The Cortex-M33 prologue is duplicated from the SSBL because (a) we may be
@ entered directly by the FSBL on a board where the SSBL is absent (e.g. a
@ dev flow that drops just the TSBL+app), and (b) re-running the prologue
@ after the SSBL did it is idempotent (the RCP BMI check skips re-seeding).
@ ----------------------------------------------------------------------------
    .section .text._tsbl_reset, "ax"
    .thumb_func
    .align   2
    .global  _tsbl_reset
_tsbl_reset:
    @ ---- Cortex-M33 prologue (idempotent re-run) ---------------------------
    ldr     r0, =0xE000ED88                 @ CPACR
    movs    r1, #0xC0
    lsls    r1, r1, #8
    str     r1, [r0]

    mrc     p7, #1, APSR_nzcv, c0, c0, #0
    bmi     1f
    mcrr    p7, #8, r0, r0, c0
    mcrr    p7, #8, r0, r0, c1
    sev
1:

    movs    r0, #0
    msr     msplim, r0

    @ ---- Validate the app footer -------------------------------------------
    ldr     r0, =BL_APP_SLOT_A_FOOTER
    ldr     r1, [r0, #BL_FOOTER_OFF_MAGIC]
    ldr     r4, =BL_FOOTER_MAGIC
    cmp     r1, r4
    bne     _tsbl_halt

    ldr     r1, [r0, #BL_FOOTER_OFF_PAYLOAD_SZ]
    ldr     r2, =(BL_APP_SLOT_A_SIZE - BL_FOOTER_SIZE)
    cmp     r1, r2
    bhi     _tsbl_halt

    ldr     r4, [r0, #BL_FOOTER_OFF_CRC32]

    ldr     r0, =BL_APP_SLOT_A_BASE
    bl      crc32_compute
    cmp     r0, r4
    bne     _tsbl_halt

    @ ---- Hand off to app ---------------------------------------------------
    ldr     r0, =BL_APP_SLOT_A_BASE
    ldr     r1, =SCB_VTOR
    str     r0, [r1]

    ldr     r1, [r0, #0]
    ldr     r2, [r0, #4]
    msr     msp, r1
    bx      r2

@ ----------------------------------------------------------------------------
@ _tsbl_halt - park on validation failure.
@ ----------------------------------------------------------------------------
    .section .text._tsbl_halt, "ax"
    .thumb_func
    .align   2
    .global  _tsbl_halt
_tsbl_halt:
    wfi
    b       _tsbl_halt
