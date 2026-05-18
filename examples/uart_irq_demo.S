@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/uart_irq_demo.S - UART0 RX interrupt echo demo (M4-E).
@
@ Boot path:
@   1. Standard M2 clocks bring-up (XOSC -> PLL_SYS @ 150 MHz -> clk_peri).
@   2. uart_init(0, 115200, 150e6) and uart_init(1, 115200, 150e6).
@   3. gpio_init(25) as output (LED).
@   4. uart_set_irq_handler(0, &uart0_isr); uart_set_irqs_enabled(0, RXIM).
@   5. uart_puts_blocking(0, prompt).
@   6. forever: wfi (woken by UART0 IRQ).
@
@ ISR (uart0_isr):
@   while (uart_is_readable(0)):
@       byte = uart_getc_blocking(0)
@       gpio_toggle(25)
@       uart_putc_blocking(0, byte)        @ echo back
@   uart_acknowledge_irq(0, RXIM)
@
@ The handler also covers the RT (RX timeout) bit so a single typed character
@ doesn't stall waiting for the FIFO to fill to the IFLS threshold.  We
@ unmask both RXIM and RTIM and ack both in the ISR.
@
@ Hardware setup:  USB-serial adapter to GP0 (TX) / GP1 (RX), 115200 8N1.
@ =============================================================================

    .include "rp2350.inc"
    .include "uart.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ LED_PIN, 25

    .section .rodata.uart_irq_banner, "a"
banner_prompt:
    .asciz "ticktrace M4-E UART IRQ echo: type away >\r\n"

@ ----------------------------------------------------------------------------
@ uart0_isr - ISR vectored from NVIC line 33.
@   Echoes every byte sitting in the RX FIFO and toggles the LED.  Acks both
@   RXIM and RTIM (timeout) at exit so we don't re-enter on a stale flag.
@ ----------------------------------------------------------------------------
    .section .text.uart0_isr, "ax"
    .thumb_func
    .global  uart0_isr
uart0_isr:
    push    {r4, lr}
.Lservice:
    movs    r0, #0
    bl      uart_is_readable
    cbz     r0, .Lack
    movs    r0, #0
    bl      uart_getc_blocking
    mov     r4, r0                          @ byte
    movs    r0, #LED_PIN
    bl      gpio_toggle
    movs    r0, #0
    mov     r1, r4
    bl      uart_putc_blocking
    b       .Lservice

.Lack:
    movs    r0, #0
    movw    r1, #(UART_INT_RXIM | UART_INT_RTIM)
    bl      uart_acknowledge_irq
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {lr}

    @ ---- Clock tree bring-up --------------------------------------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- LED on GP25 as output ------------------------------------------
    movs    r0, #LED_PIN
    bl      gpio_init
    movs    r0, #LED_PIN
    movs    r1, #1
    bl      gpio_set_dir

    @ ---- Both UARTs at 115200 (UART1 quiescent in this demo) ------------
    movs    r0, #0
    ldr     r1, =115200
    ldr     r2, =150000000
    bl      uart_init

    movs    r0, #1
    ldr     r1, =115200
    ldr     r2, =150000000
    bl      uart_init

    @ ---- Install ISR + enable RX-related IRQs on UART0 ------------------
    movs    r0, #0
    ldr     r1, =uart0_isr
    bl      uart_set_irq_handler            @ patches vector + NVIC enable

    movs    r0, #0
    movw    r1, #(UART_INT_RXIM | UART_INT_RTIM)
    bl      uart_set_irqs_enabled

    @ ---- Print prompt then sleep ----------------------------------------
    movs    r0, #0
    ldr     r1, =banner_prompt
    bl      uart_puts_blocking

.Lwait:
    wfi
    b       .Lwait

@ ---- Bundle the NVIC driver into this image (so the example links without
@      needing to modify the production DRIVER_SRC list).
    .include "src/nvic.S"
