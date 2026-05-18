@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ adc_temp_demo.S - read on-die temperature sensor every ~500 ms.
@
@ Output goes to BOTH:
@   - UART0 @ 115200 8N1 on GP0 (TX) / GP1 (RX) - for headless logging
@   - USB CDC ttyACM0 - for plug-and-play viewing on a host terminal
@
@ Format: "raw=XXXX\r\n" with XXXX as 4 hex digits of the 12-bit ADC value.
@ Convert to deg-C off-board:
@   V = 3.3 * raw / 4095
@   T_C = 27 - (V - 0.706) / 0.001721
@
@ CDC output is gated on the DTR rising edge so the first sample is not
@ lost into the void before the host terminal attaches.  UART output is
@ unconditional (no flow control to wait on).
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"
    .include "adc.inc"

    .section .rodata.demo, "a"
banner:
    .asciz "adc temp sensor:\r\n"
prefix:
    .asciz "raw="
nl:
    .asciz "\r\n"
hex_digits:
    .ascii "0123456789abcdef"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    bl      adc_init
    movs    r0, #1
    bl      adc_set_temp_sensor_enabled
    movs    r0, #ADC_CH_TEMP        @ 4 on RP2350A (Pico 2), 8 on RP2350B
    bl      adc_select_input

    ldr     r0, =banner
    bl      uart0_puts

    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ Wait for CDC DTR rising edge before entering the main loop.  See
    @ memory/feedback_cdc_banner.md for why a one-shot banner after
    @ usb_configured drops on the floor.
    movs    r5, #0
.Lwait_dtr:
    ldr     r0, =cdc_dtr
    ldr     r4, [r0]
    cmp     r4, r5
    beq     .Lwait_park
    movs    r5, r4
    cmp     r4, #0
    bne     .Lloop                  @ rising edge - start
.Lwait_park:
    bl      gpio_led_toggle
    ldr     r0, =12500000
1:  subs    r0, #1
    bne     1b
    b       .Lwait_dtr

.Lloop:
    bl      adc_read                @ r0 = raw 12-bit value
    push    {r0}

    @ "raw=" prefix to both transports
    ldr     r0, =prefix
    bl      uart0_puts
    ldr     r0, =prefix
    bl      cdc_puts

    pop     {r0}
    bl      print_u16_hex_dual

    @ "\r\n" suffix to both transports
    ldr     r0, =nl
    bl      uart0_puts
    ldr     r0, =nl
    bl      cdc_puts

    bl      gpio_led_toggle

    @ ~250 ms at 150 MHz (delay loop, 3-cycle body)
    ldr     r0, =12500000
2:  subs    r0, #1
    bne     2b
    b       .Lloop

@ -----------------------------------------------------------------------------
@ print_u16_hex_dual(r0=value) - prints 4 hex digits on UART0 AND CDC.
@ Clobbers r0-r3, r7.
@ -----------------------------------------------------------------------------
    .thumb_func
print_u16_hex_dual:
    push    {r4, r5, r6, r7, lr}
    mov     r4, r0
    ldr     r5, =hex_digits
    movs    r6, #12
1:  mov     r0, r4
    lsrs    r0, r6
    and     r0, #0xF
    ldrb    r7, [r5, r0]
    @ UART path: uart_putc_blocking(uart_idx=0, byte)
    movs    r0, #0
    mov     r1, r7
    bl      uart_putc_blocking
    @ CDC path: cdc_putc(byte)
    mov     r0, r7
    bl      cdc_putc
    subs    r6, #4
    bge     1b
    pop     {r4, r5, r6, r7, pc}

    .include "src/nvic.S"
