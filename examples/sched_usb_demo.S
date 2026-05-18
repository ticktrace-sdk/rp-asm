@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/sched_usb_demo.S - sched + spsc + sched_stats verification.
@
@ Combined T4 fixture covering all three scheduler-family drivers
@ using only LED + USB CDC.  Pipeline:
@
@   TIMER0 ALARM0 (500 ms cadence)
@     -> alarm0_isr: re-arm, push counter byte into spsc queue,
@                    task_post(T_CONSUMER)
@     -> T_CONSUMER (NVIC-dispatched, priority 0x40):
@          spsc_byte_pop, gpio_led_toggle,
@          cdc_puts "sched iter=N byte=X inv=Y cyc=Z"
@          (Y = task invocations, Z = total DWT cycles since boot)
@
@ Exercises:
@   sched.S      sched_init, task_create_traced, task_post, sched_run
@   spsc.S       spsc_byte_push (ISR), spsc_byte_pop (task)
@   sched_stats  task_create_traced, task_stats_invocations, task_stats_total
@
@ Verify:  screen /dev/ttyACM0 115200
@   expect: LED toggles 1 Hz; "sched iter=1 byte=1 inv=1 cyc=NNN" etc.,
@           one line per 500 ms.  inv increments by 1 each line, cyc
@           grows monotonically.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"
    .include "spsc.inc"

    .equ ALARM_PERIOD_US, 500000
    .equ T_CONSUMER,      0           @ task id within the scheduler

    @ ---- SPSC queue: 32-byte ring ----------------------------------------
    @ Struct = head(4) + tail(4) + mask(4) + reserved(4) + data(32) = 48 B
    .section .bss.sched_usb_spsc, "aw", %nobits
    .align   2
    .global  isr_to_task_q
isr_to_task_q:
    .space   48

    .section .data.sched_usb_state, "aw"
    .align   2
iter_count: .word 0

    .section .rodata.sched_usb, "a"
banner_uart:  .asciz "ticktrace M3+ - sched + spsc + sched_stats verification\r\n"
prefix_iter:  .asciz "sched iter="
mid_byte:     .asciz " byte="
mid_inv:      .asciz " inv="
mid_cyc:      .asciz " cyc="
suffix_crlf:  .asciz "\r\n"

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
@ alarm0_isr - TIMER0 ALARM0 handler.  ISR-context producer.
@ ----------------------------------------------------------------------------
    .section .text.alarm0_isr, "ax"
    .thumb_func
    .global  alarm0_isr
alarm0_isr:
    push    {r4, lr}

    @ Clear + re-arm
    movs    r0, #0
    movs    r1, #0
    bl      alarm_clear_irq
    bl      time_us_32
    ldr     r1, =ALARM_PERIOD_US
    add     r0, r0, r1
    mov     r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set

    @ Push iter byte to spsc
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    ldr     r0, =isr_to_task_q
    @ r1 already = new iter; use low 8 bits as the byte
    bl      spsc_byte_push

    @ Schedule the consumer task
    movs    r0, #T_CONSUMER
    bl      task_post

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ t_consumer - soft task running as an NVIC handler (sched-dispatched).
@   Pops one byte, toggles LED, prints via USB CDC.  task_create_traced
@   wraps this with cycle accounting, so task_stats_total(T_CONSUMER)
@   reports the running cycle count.
@ ----------------------------------------------------------------------------
    .section .text.t_consumer, "ax"
    .thumb_func
    .global  t_consumer
t_consumer:
    push    {r4, r5, lr}

    @ Pop byte from spsc
    ldr     r0, =isr_to_task_q
    bl      spsc_byte_pop
    @ r0: 1 = popped (byte in r1), 0 = empty
    cbz     r0, .Lt_done
    mov     r4, r1                                @ stash byte

    bl      gpio_led_toggle

    ldr     r0, =prefix_iter
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r0, [r0]
    bl      _put_uint_decimal

    ldr     r0, =mid_byte
    bl      cdc_puts
    mov     r0, r4                                @ popped byte
    and     r0, #0xFF
    bl      _put_uint_decimal

    ldr     r0, =mid_inv
    bl      cdc_puts
    movs    r0, #T_CONSUMER
    bl      task_stats_invocations
    bl      _put_uint_decimal

    ldr     r0, =mid_cyc
    bl      cdc_puts
    movs    r0, #T_CONSUMER
    bl      task_stats_total
    bl      _put_uint_decimal

    ldr     r0, =suffix_crlf
    bl      cdc_puts

.Lt_done:
    pop     {r4, r5, pc}

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

    @ ---- Initialise SPSC mask -------------------------------------------
    @ 32-byte ring -> mask = 0x1F at offset SPSC_OFF_MASK (8).
    ldr     r0, =isr_to_task_q
    movs    r1, #0x1F
    str     r1, [r0, #SPSC_OFF_MASK]

    @ ---- TIMER0 alarm0 IRQ wiring ----------------------------------------
    bl      timer_init
    movs    r0, #0                                @ TIMER0_IRQ_0
    ldr     r1, =alarm0_isr
    bl      nvic_install_handler
    movs    r0, #0
    movs    r1, #0
    bl      alarm_enable_irq                      @ TIMER0.INTE.ALARM0 = 1
    movs    r0, #0
    bl      nvic_enable_irq                       @ NVIC line 0

    bl      time_us_32
    ldr     r1, =ALARM_PERIOD_US
    add     r0, r0, r1
    mov     r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set

    @ ---- DWT cycle counter (needed for task_create_traced's wrapper) -----
    bl      dwt_init

    @ ---- Scheduler init + task registration ------------------------------
    bl      sched_init
    movs    r0, #T_CONSUMER
    ldr     r1, =t_consumer
    movs    r2, #0x40                             @ priority - mid
    bl      task_create_traced

    @ Hand the CPU to the scheduler (cpsie i + wfi loop)
    b       sched_run

    .include "src/timer.S"
    .include "src/nvic.S"
