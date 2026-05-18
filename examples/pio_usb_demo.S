@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/pio_usb_demo.S - PIO controller verification via LED + USB CDC.
@
@ Loads a hand-encoded 8-instruction program into PIO0 SM0 that
@ generates a visible ~1 Hz square wave on GP25 (the on-board LED).
@ Main loop emits "pio iter=N" once per second so we can confirm the
@ PIO is autonomous (the CPU is not toggling the LED).
@
@ Program (origin 0):
@   0: SET PINS, 1 [31]         0xFF01    LED high, delay 31
@   1: SET Y, 31                0xE05F    counter
@   2: NOP [31]                 0xBF42    delay_h: 32 cycles
@   3: JMP Y--, 2               0x0082    loop while Y != 0
@   4: SET PINS, 0 [31]         0xFF00    LED low, delay 31
@   5: SET Y, 31                0xE05F
@   6: NOP [31]                 0xBF42    delay_l
@   7: JMP Y--, 6               0x0086
@ WRAP_BOTTOM=0, WRAP_TOP=7
@
@ Per half cycle: (32 SET) + 32 * (32 NOP + 1 JMP) = 1088 PIO cycles
@ Full cycle: 2 * 1088 = 2176 PIO cycles
@ PIO clk = clk_sys / 65535 (CLKDIV max) = 150e6/65535 ~= 2289 Hz
@ Full cycle = 2176 / 2289 ~= 950 ms ~= 1.05 Hz
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .equ LED_PIN, 25

    .section .data.pio_usb_state, "aw"
    .align   2
iter_count: .word 0

    .section .rodata.pio_usb, "a"
banner_uart:    .asciz "ticktrace M5-I - PIO blink (GP25) + USB CDC verification\r\n"
prefix_pio:     .asciz "pio iter="
suffix_crlf:    .asciz "\r\n"

    .align 2
    .global pio_blink_program
pio_blink_program:
    .word 0xE081            @ 0: SET PINDIRS, 1     -> drive GP25 as output
    .word 0xFF01            @ 1: SET PINS, 1 [31]
    .word 0xE05F            @ 2: SET Y, 31
    .word 0xBF42            @ 3: NOP [31]
    .word 0x0083            @ 4: JMP Y--, 3
    .word 0xFF00            @ 5: SET PINS, 0 [31]
    .word 0xE05F            @ 6: SET Y, 31
    .word 0xBF42            @ 7: NOP [31]
    .word 0x0087            @ 8: JMP Y--, 7
    .equ PIO_BLINK_LEN, 9

@ ----------------------------------------------------------------------------
@ _put_uint_decimal
@ ----------------------------------------------------------------------------
    .section .text._put_uint_decimal, "ax"
    .thumb_func
_put_uint_decimal:
    push    {r4, r5, r6, lr}
    sub     sp, sp, #12
    mov     r4, sp
    adds    r4, #11
    movs    r5, #0
    strb    r5, [r4]
    movs    r6, #10
    cbnz    r0, 1f
    subs    r4, #1
    movs    r5, #'0'
    strb    r5, [r4]
    b       2f
1:  udiv    r2, r0, r6
    mls     r3, r2, r6, r0
    adds    r3, #'0'
    subs    r4, #1
    strb    r3, [r4]
    mov     r0, r2
    cmp     r0, #0
    bne     1b
2:  mov     r0, r4
    bl      cdc_puts
    add     sp, sp, #12
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
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
    ldr     r0, =banner_uart
    bl      uart0_puts

    @ USB CDC
    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ ---- PIO0 bring-up + program load + run ------------------------------
    movs    r0, #0                                @ PIO0
    bl      pio_init

    movs    r0, #0
    movs    r1, #LED_PIN
    bl      pio_gpio_init                         @ GP25 funcsel = PIO0 (6)

    movs    r0, #0
    ldr     r1, =pio_blink_program
    movs    r2, #PIO_BLINK_LEN
    movs    r3, #0                                @ origin = 0
    bl      pio_add_program

    @ CLKDIV max (slowest PIO clock)
    movs    r0, #0
    movs    r1, #0                                @ SM0
    movw    r2, #0xFFFF                           @ int
    movs    r3, #0                                @ frac
    bl      pio_sm_set_clkdiv

    @ Wrap 1..8 -- SET PINDIRS at addr 0 runs once at start, then SM
    @ loops in [1, 8] forever.
    movs    r0, #0
    movs    r1, #0
    movs    r2, #1                                @ bottom
    movs    r3, #8                                @ top
    bl      pio_sm_set_wrap

    @ SET pin base = LED_PIN, count = 1
    movs    r0, #0
    movs    r1, #0
    movs    r2, #LED_PIN
    movs    r3, #1
    bl      pio_sm_set_set_pins

    @ Enable SM0
    movs    r0, #0
    movs    r1, #0
    movs    r2, #1
    bl      pio_sm_set_enabled

    @ ---- Main idle: emit a CDC line per second so we can confirm the
    @ CPU is alive and PIO is running independently.
.Lloop:
    ldr     r0, =prefix_pio
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    ldr     r0, =50000000
1:  subs    r0, #1
    bne     1b
    b       .Lloop

    .include "src/nvic.S"
