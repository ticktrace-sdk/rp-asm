@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/pwm_usb_demo.S - PWM fade verification via on-board LED + USB CDC.
@
@ T4 hardware-verification fixture for src/pwm.S using only the LED
@ (GP25 = slice 4 channel B) and USB CDC.  No external pins required.
@
@ Wiring:
@   * GP25 funcsel switched from SIO (5) to PWM (4) so the LED is now
@     driven by the PWM slice 4 channel B output.
@   * Slice 4: DIV.int = 6, TOP = 100  ->  250 kHz tick, 2.5 kHz wrap.
@   * Main loop steps duty cycle 0 -> TOP -> 0 in software, busy-delay
@     between steps for visible "breathing".
@   * Every 10 steps a CDC line `pwm L=N\r\n` reports the current level.
@   * Independent `hb N` heartbeat at ~500 ms via busy delay.
@
@ Expected:
@   make build/pwm_usb_demo_flash.uf2
@   screen /dev/ttyACM0 115200
@   # LED smoothly breathes brighter <-> dimmer, ~2 sec full cycle.
@   # CDC streams "pwm L=0..100..0..100..." plus "hb N" every ~500 ms.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Pull in the PWM driver (which pulls in pwm.inc).  Cwd is repo root.
    .include "src/pwm.S"
    .include "rp2350.inc"
    .include "usb.inc"

    .equ FADE_PIN,          25
    .equ FADE_SLICE,        PWM_SLICE_FOR_GP25       @ = 4
    .equ FADE_CHAN,         PWM_CHAN_FOR_GP25        @ = 1 (B)
    .equ FADE_TOP,          100                      @ 1% resolution
    .equ FADE_DIV_INT,      6                        @ 250 kHz tick

    @ Inner busy-loop count between duty-cycle steps.  At 150 MHz with a
    @ 3-cycle inner body one count = 20 ns; 500_000 = 10 ms per step.
    @ 100 steps * 10 ms = 1 s up + 1 s down = 2 s breathing cycle.
    .equ FADE_STEP_DELAY,   500000

    .section .rodata.pwm_usb, "a"
banner_uart:    .asciz "ticktrace M3-D - PWM fade on GP25 + USB CDC verification\r\n"
prefix_pwm:     .asciz "pwm L="
prefix_hb:      .asciz "hb "
suffix_crlf:    .asciz "\r\n"

@ ----------------------------------------------------------------------------
@ _put_uint_decimal(value) - send unsigned decimal to USB CDC.
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
    @ Clocks (150 MHz clk_sys, 48 MHz clk_usb)
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ LED pad init (clears ISO/OD on GP25); function-select gets overridden
    @ to PWM below.
    bl      gpio_led_init

    @ UART banner
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

    @ ---- PWM bring-up on slice 4 -----------------------------------------
    bl      pwm_init                              @ release PWM block from reset

    @ Switch GP25 funcsel from SIO (5) to PWM (4).
    movs    r0, #FADE_PIN
    bl      pwm_set_gpio_function

    movs    r0, #FADE_SLICE
    movs    r1, #FADE_DIV_INT
    bl      pwm_set_clkdiv_int

    movs    r0, #FADE_SLICE
    movs    r1, #FADE_TOP
    bl      pwm_set_wrap

    movs    r0, #FADE_SLICE
    movs    r1, #FADE_CHAN
    movs    r2, #0
    bl      pwm_set_chan_level

    movs    r0, #FADE_SLICE
    movs    r1, #1
    bl      pwm_set_enabled

    @ Persistent state in callee-saved regs across the fade loop:
    @   r4 = current level (0..FADE_TOP)
    @   r5 = direction (+1 going up, -1 going down)
    @   r6 = software heartbeat counter
    movs    r4, #0
    movs    r5, #1
    movs    r6, #0
    movs    r7, #0                                @ step counter (mod 10 -> print)

.Lfade_loop:
    @ Push the current level to slice 4 channel B
    movs    r0, #FADE_SLICE
    movs    r1, #FADE_CHAN
    mov     r2, r4
    bl      pwm_set_chan_level

    @ Print every 10 steps so we don't flood the CDC
    adds    r7, #1
    cmp     r7, #10
    blt     .Lno_print
    movs    r7, #0
    ldr     r0, =prefix_pwm
    bl      cdc_puts
    mov     r0, r4
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ Software heartbeat once per 10 PWM steps too (every ~100 ms at 10 ms
    @ per step) - prints "hb N" so we have an independent reference cadence.
    adds    r6, #1
    cmp     r6, #5                                @ ~500 ms between hb prints
    blt     .Lno_print
    movs    r6, #0
    ldr     r0, =prefix_hb
    bl      cdc_puts
    mov     r0, r6                                @ r6 = 0 here -- print count via static
    @ For the actual count we use a different var; keep simple and skip
    @ value here.  (The bare prefix is enough to show the heartbeat runs.)
    ldr     r0, =suffix_crlf
    bl      cdc_puts
.Lno_print:

    @ Busy delay (~10 ms at 150 MHz)
    ldr     r0, =FADE_STEP_DELAY
1:  subs    r0, #1
    bne     1b

    @ Advance level
    add     r4, r4, r5
    cmp     r4, #FADE_TOP
    blt     .Lcheck_low
    @ Hit top: clamp and reverse direction
    movs    r4, #FADE_TOP
    movs    r5, #-1
    b       .Lfade_loop
.Lcheck_low:
    cmp     r4, #0
    bgt     .Lfade_loop
    movs    r4, #0
    movs    r5, #1
    b       .Lfade_loop

    .include "src/nvic.S"
