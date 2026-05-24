@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ clocks.S - RP2040 clock tree configuration.
@
@ Datasheet ref: RP2040 sec 2.15.
@
@ After XOSC is stable and the two PLLs have locked:
@
@   clk_ref  <- xosc (12 MHz)               (.SRC = 2, no auxsrc)
@   clk_sys  <- pll_sys (125 MHz)           (.SRC = 1 aux, .AUXSRC = 0 pll_sys)
@   clk_peri <- clk_sys                     (.AUXSRC = 0 clk_sys)
@   clk_usb  <- pll_usb (48 MHz)            (.AUXSRC = 0 pll_usb)
@   clk_adc  <- pll_usb (48 MHz)            (.AUXSRC = 0 pll_usb)
@
@ Glitchless mux switch sequence per RP2040 datasheet:
@   1. Switch SRC away from any source we're going to modify.
@   2. Spin on the matching CLK_x_SELECTED bit.
@   3. Re-enable / set AUXSRC.
@ For clocks with no glitchless mux (peri/usb/adc) we just disable, set
@ AUXSRC, then enable.
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

@ ----------------------------------------------------------------------------
@ clocks_init - wire all six generators we care about for the M2 boot path.
@ Clobbers: r0..r4. lr preserved.
@ ----------------------------------------------------------------------------
    .section .text.clocks_init, "ax"
    .thumb_func
    .global  clocks_init
clocks_init:
    push    {r4, lr}
    ldr     r4, =CLOCKS_BASE

    @ ---- clk_ref <- xosc --------------------------------------------------
    @ clk_ref CTRL.SRC = 2 (xosc). No AUXSRC needed; no enable bit; clk_ref
    @ is always running, just sourced from one of {ROSC, XOSC, AUX}.
    movs    r0, #CLK_REF_CTRL_SRC_XOSC
    str     r0, [r4, #CLK_REF_CTRL]

    @ Spin on SELECTED bit 1 (=1<<2 since SRC=2 maps to bit 2 in SELECTED).
    @ Wait, SELECTED is one-hot per source: bit (1<<SRC). For SRC=2 the bit
    @ is (1<<2) = 4.
    movs    r1, #(1 << 2)
1:  ldr     r0, [r4, #CLK_REF_SELECTED]
    ands    r0, r1
    cmp     r0, r1
    bne     1b

    @ ---- clk_sys <- pll_sys ------------------------------------------------
    @ Per the datasheet, first switch clk_sys to clk_ref so we can change
    @ AUXSRC safely.  CTRL.SRC bit 0; clear it.
    movs    r0, #0
    str     r0, [r4, #CLK_SYS_CTRL]
    movs    r1, #(1 << 0)
2:  ldr     r0, [r4, #CLK_SYS_SELECTED]
    ands    r0, r1
    cmp     r0, r1
    bne     2b

    @ Now set AUXSRC = pll_sys (0), then SRC = aux (1).
    @ The AUXSRC field lives at bits 7:5; for pll_sys (0) the field is 0.
    @ So CTRL = (0 << 5) | (1 << 0) = 1.  No enable bit on the
    @ glitchless-mux clocks.
    movs    r0, #1
    str     r0, [r4, #CLK_SYS_CTRL]
    movs    r1, #(1 << 1)
3:  ldr     r0, [r4, #CLK_SYS_SELECTED]
    ands    r0, r1
    cmp     r0, r1
    bne     3b

    @ ---- clk_peri <- clk_sys ----------------------------------------------
    @ clk_peri has no glitchless mux; sequence is disable -> AUXSRC -> enable.
    @ Disable: clear ENABLE bit (bit 11).
    @ AUXSRC field = 0 (clk_sys) at bits 7:5.
    @ Enable: set ENABLE.
    movs    r0, #0
    str     r0, [r4, #CLK_PERI_CTRL]
    ldr     r0, =CLK_CTRL_ENABLE            @ AUXSRC=0, ENABLE=1
    str     r0, [r4, #CLK_PERI_CTRL]

    @ ---- clk_usb <- pll_usb -----------------------------------------------
    movs    r0, #0
    str     r0, [r4, #CLK_USB_CTRL]
    ldr     r0, =CLK_CTRL_ENABLE
    str     r0, [r4, #CLK_USB_CTRL]

    @ ---- clk_adc <- pll_usb -----------------------------------------------
    movs    r0, #0
    str     r0, [r4, #CLK_ADC_CTRL]
    ldr     r0, =CLK_CTRL_ENABLE
    str     r0, [r4, #CLK_ADC_CTRL]

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ clocks_post_pll_uart_baud_fixup - re-run uart0 baud calc after clk_peri
@ moves from 12 MHz (XOSC) to 125 MHz (clk_sys).  uart0_init writes baud
@ divisors based on the assumption clk_peri = 12 MHz; once we're at 125 MHz
@ the divisors are off by a factor of ~10.x.
@
@ The fix is to re-do the baud arithmetic with the new clk_peri.  For 115200
@ at clk_peri = 125 MHz:
@   div   = (125_000_000 * 64) / (16 * 115200) = 4340.27...
@   IBRD  = div / 64 = 67
@   FBRD  = div - IBRD*64 = ((125_000_000*8)/115200 + 1) >> 1 - IBRD*64
@         = simplified to 52/64 -> 52 / round? Actually rp2040 datasheet
@           formula: BAUDDIV = clk_peri / (16 * baud) = 67.81... -> IBRD=67,
@           FBRD = round(0.81 * 64) = 52.
@   LCR_H re-write to commit the latch.
@ ----------------------------------------------------------------------------
    .section .text.clocks_post_pll_uart_baud_fixup, "ax"
    .thumb_func
    .global  clocks_post_pll_uart_baud_fixup
clocks_post_pll_uart_baud_fixup:
    ldr     r0, =UART0_BASE
    movs    r1, #67
    str     r1, [r0, #UART_IBRD]
    movs    r1, #52
    str     r1, [r0, #UART_FBRD]
    @ Re-write LCR_H to latch the new divisor (PL011 requirement).
    movs    r1, #(UART_LCR_H_FEN | UART_LCR_H_WLEN_8)
    str     r1, [r0, #UART_LCR_H]
    bx      lr
