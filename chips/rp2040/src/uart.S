@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ uart.S - RP2040 UART (ARM PL011) driver, M2 subset.
@
@ Datasheet ref: RP2040 sec 4.2; the PL011 IP itself is documented in
@ ARM DDI 0183 (PrimeCell UART).
@
@ Public API (AAPCS):
@   uart0_init                    set up UART0 @ 115200 8N1 FEN, default
@                                  pins (GP0 TX / GP1 RX), assumes
@                                  clk_peri = 12 MHz (XOSC default).
@   uart0_putc(byte)              spin while FR.TXFF; str DR
@   uart0_puts(ptr)               null-terminated string
@   uart0_tx_wait_blocking        spin while FR.BUSY
@
@ Compared to the RP2350 PL011 driver: the IP and register layout are
@ identical; only the base address (0x40034000 vs 0x40070000) and the
@ RESETS bit (22 vs 26) differ.
@
@ Baud divisor math for 115200 8N1 at clk_peri = 12 MHz:
@   div    = (12_000_000 * 64) / (16 * 115200) = 416.67
@   IBRD   = 6,  FBRD = 33  (matches RP2350 12 MHz divisors exactly)
@ Once clk_peri reaches 125 MHz via pll_sys, the caller invokes
@ clocks_post_pll_uart_baud_fixup which rewrites the divisors.
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

@ ----------------------------------------------------------------------------
@ uart0_init - bring UART0 out of reset, configure GP0/GP1 as TX/RX,
@              program 115200 8N1 FEN for clk_peri = 12 MHz.
@ Clobbers: r0..r3.
@ ----------------------------------------------------------------------------
    .section .text.uart0_init, "ax"
    .thumb_func
    .global  uart0_init
uart0_init:
    @ ---- 1. RESETS_RESET CLR uart0 + wait for RESET_DONE ------------------
    movs    r3, #1
    lsls    r3, #RESETS_uart0
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r3, [r0]

    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r1, [r0]
    ands    r1, r3
    cmp     r1, r3
    bne     1b

    @ ---- 2. PADS_BANK0[0] CLR = OD ; PADS_BANK0[1] CLR = OD ---------------
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (0 * 4)
    movs    r1, #PADS_OD
    str     r1, [r0]
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (1 * 4)
    str     r1, [r0]

    @ ---- 3. IO_BANK0[0] CTRL = UART ; IO_BANK0[1] CTRL = UART -------------
    ldr     r0, =IO_BANK0_BASE + 4 + (0 * 8)
    movs    r1, #GPIO_FUNC_UART
    str     r1, [r0]
    ldr     r0, =IO_BANK0_BASE + 4 + (1 * 8)
    str     r1, [r0]

    @ ---- 4. Baud divisor for 115200 at clk_peri = 12 MHz ------------------
    ldr     r0, =UART0_BASE
    movs    r1, #6                          @ IBRD
    str     r1, [r0, #UART_IBRD]
    movs    r1, #33                         @ FBRD
    str     r1, [r0, #UART_FBRD]

    @ ---- 5. LCR_H = WLEN_8 | FEN (=0x70) ----------------------------------
    movs    r1, #(UART_LCR_H_FEN | UART_LCR_H_WLEN_8)
    str     r1, [r0, #UART_LCR_H]

    @ ---- 6. CR = RXE | TXE | UARTEN (=0x301) ------------------------------
    ldr     r1, =(UART_CR_RXE | UART_CR_TXE | UART_CR_UARTEN)
    str     r1, [r0, #UART_CR]

    bx      lr

@ ----------------------------------------------------------------------------
@ uart0_putc - blocking single-byte TX.
@   r0 = byte
@ Clobbers: r1, r2.
@ ----------------------------------------------------------------------------
    .section .text.uart0_putc, "ax"
    .thumb_func
    .global  uart0_putc
uart0_putc:
    ldr     r1, =UART0_BASE
1:  ldr     r2, [r1, #UART_FR]
    movs    r3, #UART_FR_TXFF
    ands    r2, r3
    bne     1b                             @ FR.TXFF set -> FIFO full, wait
    str     r0, [r1, #UART_DR]
    bx      lr

@ ----------------------------------------------------------------------------
@ uart0_puts - blocking null-terminated string TX.
@   r0 = ptr
@ Clobbers: r0..r3.
@ ----------------------------------------------------------------------------
    .section .text.uart0_puts, "ax"
    .thumb_func
    .global  uart0_puts
uart0_puts:
    push    {r4, lr}
    mov     r4, r0
1:  ldrb    r0, [r4]
    cmp     r0, #0
    beq     2f
    bl      uart0_putc
    adds    r4, #1
    b       1b
2:  pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ uart0_tx_wait_blocking - spin while FR.BUSY.
@ Clobbers: r0..r2.
@ ----------------------------------------------------------------------------
    .section .text.uart0_tx_wait_blocking, "ax"
    .thumb_func
    .global  uart0_tx_wait_blocking
uart0_tx_wait_blocking:
    ldr     r0, =UART0_BASE
1:  ldr     r1, [r0, #UART_FR]
    movs    r2, #UART_FR_BUSY
    ands    r1, r2
    bne     1b
    bx      lr
