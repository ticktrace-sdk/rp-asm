@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/trace_usb_demo.S - DWT cycle counter verification via USB CDC.
@
@ src/trace.S exposes the full CoreSight stack (DWT, ITM, TPIU, ETM)
@ but those need an external SWD/SWO probe to capture.  The one piece
@ we can verify with just LED + USB is the DWT cycle counter, which is
@ purely a CPU-side feature - dwt_init enables CYCCNT, and reading it
@ should advance at the clk_sys rate (= 150 MHz post-clocks_init).
@
@ Demo: time a known busy loop (3M cycles at 3 cycles per iteration)
@ and report the measured count.  Expect delta ~= 3_000_000 within a
@ few cycles of overhead.
@
@ Verify:  screen /dev/ttyACM0 115200
@   expect: "trace busy_loop_3M cyc=3000NNN" once per second, where the
@           NNN measures the call/loop overhead; same value every iter.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "trace.inc"
    .include "usb.inc"

    .equ BUSY_ITERS, 1000000                      @ 3 cycles each = 3M cycles

    .section .data.trace_usb_state, "aw"
    .align   2
iter_count: .word 0

    .section .rodata.trace_usb, "a"
banner_uart:    .asciz "ticktrace trace - DWT cycle counter verification\r\n"
prefix_iter:    .asciz "trace iter="
mid_cyc:        .asciz " busy_loop_3M cyc="
suffix_crlf:    .asciz "\r\n"

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

    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ ---- Enable DWT cycle counter ----------------------------------------
    bl      dwt_init

.Liter_loop:
    bl      gpio_led_toggle

    @ Snapshot, busy-spin, snapshot again, delta.
    bl      dwt_cycles_read                       @ r0 = t0
    mov     r4, r0
    ldr     r5, =BUSY_ITERS
1:  subs    r5, #1
    bne     1b
    bl      dwt_cycles_read                       @ r0 = t1
    sub     r4, r0, r4                            @ delta

    ldr     r0, =prefix_iter
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      _put_uint_decimal

    ldr     r0, =mid_cyc
    bl      cdc_puts
    mov     r0, r4
    bl      _put_uint_decimal

    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ ~500 ms pause between iterations
    ldr     r0, =25000000
2:  subs    r0, #1
    bne     2b
    b       .Liter_loop

    .include "src/nvic.S"
