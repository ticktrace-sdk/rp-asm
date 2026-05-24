@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ pll.S - RP2040 PLL bring-up (sys @ 125 MHz, usb @ 48 MHz).
@
@ Datasheet ref: RP2040 sec 2.18.
@
@ pll_sys @ 125 MHz from 12 MHz XOSC reference:
@   REFDIV   = 1   -> ref = 12 MHz
@   FBDIV    = 125 -> VCO = 1500 MHz
@   POSTDIV1 = 6
@   POSTDIV2 = 2   -> fout = 1500 / (6*2) = 125 MHz
@
@ pll_usb @ 48 MHz from 12 MHz XOSC reference:
@   REFDIV   = 1   -> ref = 12 MHz
@   FBDIV    = 100 -> VCO = 1200 MHz
@   POSTDIV1 = 5
@   POSTDIV2 = 5   -> fout = 1200 / (5*5) = 48 MHz
@
@ Each pll_init() does, in order:
@   1. RESETS_RESET CLR for the PLL block, spin on RESET_DONE.
@   2. Write FBDIV_INT and CS.REFDIV.
@   3. Power on the VCO + drop PD: PWR_CLR = (VCOPD | PD).
@   4. Spin on CS.LOCK.
@   5. Write PRIM = (POSTDIV1<<16) | (POSTDIV2<<12).
@   6. Power on the post-divider: PWR_CLR = POSTDIVPD.
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

@ ----------------------------------------------------------------------------
@ pll_init - bring up a single PLL with the supplied parameters.
@   r0 = PLL base (PLL_SYS_BASE or PLL_USB_BASE)
@   r1 = RESETS bit position for this PLL (RESETS_pll_sys or RESETS_pll_usb)
@   r2 = FBDIV value
@   r3 = (POSTDIV1 << 16) | (POSTDIV2 << 12)
@ Clobbers: r0..r5, lr preserved.
@
@ Atomic alias addressing: each peripheral register has SET/CLR/XOR aliases
@ at offsets +0x2000/+0x3000/+0x1000 from the register itself. To atomic-CLR
@ register R inside peripheral P, write to P + ATOMIC_CLR + R.
@ ----------------------------------------------------------------------------
    .section .text.pll_init, "ax"
    .thumb_func
    .global  pll_init
pll_init:
    push    {r4, r5, lr}
    mov     r4, r0                          @ r4 = PLL base
    mov     r5, r3                          @ r5 = PRIM word

    @ ---- 1. Deassert the PLL reset, wait for RESET_DONE -------------------
    movs    r0, #1
    lsls    r0, r1                          @ r0 = 1 << RESETS_pll_*
    ldr     r3, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r0, [r3]

    ldr     r3, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r1, [r3]
    ands    r1, r0
    cmp     r1, r0
    bne     1b

    @ ---- 2. FBDIV + REFDIV=1 ----------------------------------------------
    str     r2, [r4, #PLL_FBDIV_INT]
    movs    r0, #1
    str     r0, [r4, #PLL_CS]               @ CS.REFDIV = 1, BYPASS = 0

    @ ---- 3. Atomic CLR (VCOPD | PD) in PLL_PWR ----------------------------
    movs    r0, #(PLL_PWR_VCOPD | PLL_PWR_PD)
    movs    r3, #PLL_PWR
    ldr     r1, =ATOMIC_CLR
    adds    r3, r1                          @ r3 = ATOMIC_CLR + PLL_PWR
    str     r0, [r4, r3]                    @ PLL_BASE + ATOMIC_CLR + PLL_PWR

    @ ---- 4. Spin on CS.LOCK (bit 31) --------------------------------------
2:  ldr     r0, [r4, #PLL_CS]
    asrs    r0, r0, #31                     @ r0 = -1 if LOCK, 0 otherwise
    cmp     r0, #0
    beq     2b

    @ ---- 5. PRIM = (POSTDIV1 << 16) | (POSTDIV2 << 12) --------------------
    str     r5, [r4, #PLL_PRIM]

    @ ---- 6. Atomic CLR POSTDIVPD in PLL_PWR -------------------------------
    movs    r0, #PLL_PWR_POSTDIVPD
    movs    r3, #PLL_PWR
    ldr     r1, =ATOMIC_CLR
    adds    r3, r1
    str     r0, [r4, r3]

    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ pll_sys_125_mhz - convenience wrapper: REFDIV=1 FBDIV=125 POSTDIV=6/2.
@ ----------------------------------------------------------------------------
    .section .text.pll_sys_125_mhz, "ax"
    .thumb_func
    .global  pll_sys_125_mhz
pll_sys_125_mhz:
    ldr     r0, =PLL_SYS_BASE
    movs    r1, #RESETS_pll_sys
    movs    r2, #125
    ldr     r3, =((6 << 16) | (2 << 12))
    b       pll_init

@ ----------------------------------------------------------------------------
@ pll_usb_48_mhz - convenience wrapper: REFDIV=1 FBDIV=100 POSTDIV=5/5.
@ ----------------------------------------------------------------------------
    .section .text.pll_usb_48_mhz, "ax"
    .thumb_func
    .global  pll_usb_48_mhz
pll_usb_48_mhz:
    ldr     r0, =PLL_USB_BASE
    movs    r1, #RESETS_pll_usb
    movs    r2, #100
    ldr     r3, =((5 << 16) | (5 << 12))
    b       pll_init
