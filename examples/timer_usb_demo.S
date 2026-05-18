@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/timer_usb_demo.S - TIMER0 alarm verification via LED + USB CDC.
@
@ T4 hardware-verification fixture for src/timer.S using only the two
@ peripherals every Pico 2 has hooked up out of the box: GP25 LED and
@ the USB device port.
@
@ Wiring:
@   * TIMER0 ALARM0 fires every 500 ms.  The ISR toggles GP25 and bumps
@     a `tick_pending` flag.  Main loop polls the flag, sends "tick N\r\n"
@     over USB CDC, sleeps in wfi.
@   * USB CDC enumerates as /dev/ttyACM0 (ticktrace M3-B alarm).
@
@ Verify (on a Linux host):
@   make build/timer_usb_demo_flash.uf2
@   # BOOTSEL + drag onto the RP2350 drive
@   screen /dev/ttyACM0 115200
@   # expect: LED toggles ~1 Hz (500 ms ON, 500 ms OFF)
@   # expect: "tick 1\r\n", "tick 2\r\n", ... one line every 500 ms
@   # (LED transitions and CDC lines should be synchronised)
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .equ ALARM_PERIOD_US, 500000           @ 500 ms

@ ----------------------------------------------------------------------------
@ Mutable state.  `tick_pending` is set by the ISR, cleared by main.
@ `tick_count` is updated only in the ISR so it's racy-but-monotonic on read.
@ ----------------------------------------------------------------------------
    .section .data.timer_usb, "aw"
    .align   2
    .global  tick_pending
tick_pending:   .word 0
    .global  tick_count
tick_count:     .word 0

    .section .rodata.timer_usb, "a"
banner_uart:    .asciz "ticktrace M3-B - timer alarm + USB CDC verification\r\n"
prefix_tick:    .asciz "tick "
prefix_hb:      .asciz "hb "
prefix_t:       .asciz " t="
prefix_alarm:   .asciz " alarm0="
suffix_crlf:    .asciz "\r\n"

@ ----------------------------------------------------------------------------
@ alarm0_isr - TIMER0_IRQ_0 handler.  Re-arm + clear + visible side effect.
@ Does NOT touch USB DPRAM directly; just bumps a flag/counter the main loop
@ drains.  Cycle budget: ~30 cycles.
@ ----------------------------------------------------------------------------
    .section .text.alarm0_isr, "ax"
    .thumb_func
    .global  alarm0_isr
alarm0_isr:
    push    {r4, lr}

    @ Clear the alarm IRQ flag (W1C) before re-arming.
    movs    r0, #0
    movs    r1, #0
    bl      alarm_clear_irq

    @ Schedule next alarm = TIMERAWL + 500 000 us
    bl      time_us_32
    ldr     r1, =ALARM_PERIOD_US
    add     r0, r0, r1
    mov     r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set

    @ Visible side effect on GP25
    bl      gpio_led_toggle

    @ Bump the count + set the pending flag
    ldr     r0, =tick_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    ldr     r0, =tick_pending
    movs    r1, #1
    str     r1, [r0]

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ _put_uint_decimal(value) - send unsigned decimal to USB CDC, no leading zeros.
@   r0 = value.  Clobbers r0-r3.  Uses a small stack buffer (10 ASCII digits +
@   NUL = 11 bytes, padded to 12 for alignment).
@ ----------------------------------------------------------------------------
    .section .text._put_uint_decimal, "ax"
    .thumb_func
_put_uint_decimal:
    push    {r4, r5, r6, lr}
    sub     sp, sp, #12
    mov     r4, sp
    adds    r4, #11                                @ r4 = end of buffer
    movs    r5, #0
    strb    r5, [r4]                               @ NUL terminator
    movs    r6, #10                                @ divisor

    @ Special-case zero so the loop always emits at least one digit.
    cbnz    r0, 1f
    subs    r4, #1
    movs    r5, #'0'
    strb    r5, [r4]
    b       2f
1:
    udiv    r2, r0, r6                             @ r2 = value / 10
    mls     r3, r2, r6, r0                         @ r3 = value - r2*10 = digit
    adds    r3, #'0'
    subs    r4, #1
    strb    r3, [r4]
    mov     r0, r2                                 @ value = quotient
    cmp     r0, #0
    bne     1b
2:
    mov     r0, r4                                 @ src = buffer start
    bl      cdc_puts
    add     sp, sp, #12
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ main - bring up clocks + USB + timer; idle on wfi; flush tick lines on wake.
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clocks (XOSC -> PLL_SYS=150 MHz, PLL_USB=48 MHz) -----------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- LED + UART status banner -----------------------------------------
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner_uart
    bl      uart0_puts

    @ ---- USB CDC ----------------------------------------------------------
    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ ---- TIMER0 alarm0 ----------------------------------------------------
    bl      timer_init
    movs    r0, #0                                @ TIMER0_IRQ_0 = NVIC line 0
    ldr     r1, =alarm0_isr
    bl      nvic_install_handler
    movs    r0, #0
    movs    r1, #0
    bl      alarm_enable_irq                      @ INTE.ALARM0 = 1
    movs    r0, #0
    bl      nvic_enable_irq                       @ NVIC line 0

    @ Schedule the first alarm 500 ms in the future
    bl      time_us_32
    ldr     r1, =ALARM_PERIOD_US
    add     r0, r0, r1
    mov     r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set

    @ ---- Diagnostic loop ---------------------------------------------------
    @ Two independent heartbeats so we can tell what's working on hardware:
    @
    @   (A) tick_pending - set by alarm0_isr.  If we see "tick N" lines,
    @       the TIMER0 alarm IRQ path works end-to-end.
    @   (B) heartbeat   - main loop's own software-delay heartbeat.  If we
    @       see "hb N" lines but no "tick N", the alarm IRQ doesn't fire
    @       (and we know the USB + LED + CDC path is fine).  If neither
    @       prints, something more fundamental is wrong.
    @
    @ Heartbeat uses a busy loop sized for ~500 ms at 150 MHz clk_sys.
    @ Counter and pending word live in registers we reuse below.
    movs    r4, #0                                @ hb_count = 0

.Lloop:
    @ (A) Drain alarm tick if pending
    ldr     r0, =tick_pending
    ldr     r1, [r0]
    cbz     r1, 1f
    movs    r1, #0
    str     r1, [r0]
    ldr     r0, =prefix_tick
    bl      cdc_puts
    ldr     r0, =tick_count
    ldr     r0, [r0]
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts
1:
    @ (B) Software heartbeat: ~500 ms busy delay then print, toggle LED.
    @ At 150 MHz a 3-cycle inner body needs 25M iterations for 500 ms.
    ldr     r0, =25000000
2:  subs    r0, #1
    bne     2b

    @ Toggle LED directly from main loop (bypasses the alarm path).
    bl      gpio_led_toggle

    @ Print "hb N t=<TIMERAWL> armed=<ARMED> inte=<INTE> intr=<INTR> alarm0=<ALARM0>\r\n"
    ldr     r0, =prefix_hb
    bl      cdc_puts
    adds    r4, #1
    mov     r0, r4
    bl      _put_uint_decimal

    ldr     r0, =prefix_t
    bl      cdc_puts
    bl      time_us_32
    bl      _put_uint_decimal

    @ ALARM0 target (re-armed by the ISR each fire; should increment by
    @ ~500000 us per tick).
    ldr     r0, =prefix_alarm
    bl      cdc_puts
    ldr     r5, =0x400b0000                       @ TIMER0_BASE
    ldr     r0, [r5, #0x10]                       @ ALARM0
    bl      _put_uint_decimal

    ldr     r0, =suffix_crlf
    bl      cdc_puts

    b       .Lloop

@ ---- Bundle the M3-B driver objects into this image -----------------------
    .include "src/timer.S"
    .include "src/nvic.S"
