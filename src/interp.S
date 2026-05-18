@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ interp.S - RP2350 SIO interpolator driver (INTERP0 / INTERP1).
@
@ Each core has two interpolators (INTERP0 at SIO+0x80, INTERP1 at +0xC0).
@ Each interpolator has:
@   ACCUM0, ACCUM1                two 32-bit accumulators
@   BASE0, BASE1, BASE2           three 32-bit bases
@   CTRL_LANE0, CTRL_LANE1        per-lane configuration
@   PEEK_LANE0, _1, _FULL         read result without advancing
@   POP_LANE0,  _1, _FULL         read result + advance accum per CTRL
@   ACCUM0_ADD, ACCUM1_ADD        write-only: ACCUM += value (no shift/mask)
@   BASE_1AND0                    write-only: BASE1<<32 | BASE0 (atomic pair)
@
@ Result formula (default CTRL = 0):
@   raw      = (ACCUMn >> CTRL.SHIFT)
@   masked   = raw & ((1 << (MASK_MSB + 1)) - 1) & ~((1 << MASK_LSB) - 1)
@   signed   = (CTRL.SIGNED) ? sign-extend from MASK_MSB : masked
@   resultN  = signed + BASEn
@
@ Public API (minimal - covers the common verification + use cases):
@   interp_set_accum(idx, lane, value)
@   interp_set_base (idx, lane, value)
@   interp_set_ctrl (idx, lane, ctrl_word)
@   interp_peek     (idx, which) -> result            which = 0/1/2 (FULL)
@   interp_pop      (idx, which) -> result + advance
@
@ idx = 0 (INTERP0) or 1 (INTERP1).
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ INTERP0_OFFSET,    0x080
    .equ INTERP_STRIDE,     0x040
    .equ INTERP_ACCUM0,     0x00
    .equ INTERP_ACCUM1,     0x04
    .equ INTERP_BASE0,      0x08
    .equ INTERP_BASE1,      0x0C
    .equ INTERP_BASE2,      0x10
    .equ INTERP_POP_LANE0,  0x14
    .equ INTERP_POP_LANE1,  0x18
    .equ INTERP_POP_FULL,   0x1C
    .equ INTERP_PEEK_LANE0, 0x20
    .equ INTERP_PEEK_LANE1, 0x24
    .equ INTERP_PEEK_FULL,  0x28
    .equ INTERP_CTRL_LANE0, 0x2C
    .equ INTERP_CTRL_LANE1, 0x30

@ ----------------------------------------------------------------------------
@ _interp_base(idx) -> r0 = SIO_BASE + interpN offset
@ Internal macro (idx in r0, base out in r0; clobbers r1).
@ ----------------------------------------------------------------------------
.macro M_INTERP_BASE base, idx, scratch
    ldr     \base, =SIO_BASE + INTERP0_OFFSET
    movs    \scratch, #INTERP_STRIDE
    mul     \scratch, \scratch, \idx          @ no S flag - works with r12
    add     \base, \base, \scratch
.endm

@ ----------------------------------------------------------------------------
@ interp_set_accum(idx, lane, value) - ACCUM[lane] = value.
@ ----------------------------------------------------------------------------
    .section .text.interp_set_accum, "ax"
    .thumb_func
    .global  interp_set_accum
interp_set_accum:
    M_INTERP_BASE r3, r0, r12
    @ lane=0 -> offset 0x00, lane=1 -> offset 0x04
    lsls    r1, r1, #2
    str     r2, [r3, r1]
    bx      lr

@ ----------------------------------------------------------------------------
@ interp_set_base(idx, lane, value) - BASE[lane] = value.  lane = 0..2.
@ ----------------------------------------------------------------------------
    .section .text.interp_set_base, "ax"
    .thumb_func
    .global  interp_set_base
interp_set_base:
    M_INTERP_BASE r3, r0, r12
    lsls    r1, r1, #2
    adds    r1, #INTERP_BASE0
    str     r2, [r3, r1]
    bx      lr

@ ----------------------------------------------------------------------------
@ interp_set_ctrl(idx, lane, ctrl_word) - CTRL_LANE[lane] = ctrl_word.
@ ----------------------------------------------------------------------------
    .section .text.interp_set_ctrl, "ax"
    .thumb_func
    .global  interp_set_ctrl
interp_set_ctrl:
    M_INTERP_BASE r3, r0, r12
    lsls    r1, r1, #2
    adds    r1, #INTERP_CTRL_LANE0
    str     r2, [r3, r1]
    bx      lr

@ ----------------------------------------------------------------------------
@ interp_peek(idx, which) -> r0 = result.  which = 0/1/2 (FULL).
@ Does not advance accumulators.
@ ----------------------------------------------------------------------------
    .section .text.interp_peek, "ax"
    .thumb_func
    .global  interp_peek
interp_peek:
    M_INTERP_BASE r3, r0, r12
    lsls    r1, r1, #2
    adds    r1, #INTERP_PEEK_LANE0
    ldr     r0, [r3, r1]
    bx      lr

@ ----------------------------------------------------------------------------
@ interp_pop(idx, which) -> r0 = result.  Reads + advances accumulators.
@ ----------------------------------------------------------------------------
    .section .text.interp_pop, "ax"
    .thumb_func
    .global  interp_pop
interp_pop:
    M_INTERP_BASE r3, r0, r12
    lsls    r1, r1, #2
    adds    r1, #INTERP_POP_LANE0
    ldr     r0, [r3, r1]
    bx      lr
