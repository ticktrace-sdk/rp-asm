@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/multicore_usb_demo.S - dual-core verification via LED + USB CDC.
@
@ Core 0:
@   * standard boot (clocks, USB CDC, banner)
@   * gpio_led_init - configure GP25 pad + IO_BANK0 funcsel
@   * launch core 1 via multicore_launch_core1
@   * main loop: prints "c0 alive N" once per second over USB CDC
@
@ Core 1:
@   * own M33 prologue (CPACR enable CP7, seed RCP, MSPLIM = 0)
@   * busy-loop toggling GP25 via SIO_GPIO_OUT_XOR at ~2 Hz
@
@ Two independent observables prove both cores are running:
@   - LED blinks (only core 1 touches it)
@   - CDC keeps streaming "c0 alive N" (only core 0 talks to host)
@
@ Vector-table strategy: both cores share core 0's _ram_vectors (single
@ table, VTOR points there on both cores).  multicore_launch_core1's
@ vtable arg = &_vectors so core 1's bootrom sets VTOR to the same RAM
@ table.  Per-core separate tables would just allocate a second
@ _ram_vectors_c1 and pass that instead.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .equ LED_PIN_BIT, (1 << 25)
    .equ CORE1_STACK_SIZE, 1024

@ ---- Core 1's stack: top of region is _core1_stack_top ---------------------
    .section .bss.core1_stack, "aw", %nobits
    .align   3                                    @ 8-byte aligned SP
_core1_stack:
    .space   CORE1_STACK_SIZE
_core1_stack_top:

    .section .data.multicore_state, "aw"
    .align   2
iter_count: .word 0

    .section .rodata.multicore_usb, "a"
banner_uart:    .asciz "ticktrace M6 - dual-core LED + USB CDC verification\r\n"
prefix_c0:      .asciz "c0 alive "
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
@ core1_entry - first thing core 1 runs after the bootrom hands off.
@ Does its own M33 prologue (separate from core 0's), then enters the LED
@ blink loop.  Never returns.
@ ----------------------------------------------------------------------------
    .section .text.core1_entry, "ax"
    .thumb_func
    .global  core1_entry
core1_entry:
    @ ---- M33 prologue ----------------------------------------------------
    @ Each core has its own CPACR and MSPLIM banked at the same SCS addr.
    ldr     r0, =0xE000ED88                       @ CPACR
    movs    r1, #0xC0
    lsls    r1, #8                                @ CP7 = 0xC000
    str     r1, [r0]

    mrc     p7, #1, APSR_nzcv, c0, c0, #0
    bmi     1f
    mcrr    p7, #8, r0, r0, c0
    mcrr    p7, #8, r0, r0, c1
    sev
1:
    movs    r0, #0
    msr     msplim, r0

    @ ---- Blink loop ------------------------------------------------------
    @ Core 0 has already set GP25 funcsel = SIO and PAD ISO/OD cleared via
    @ gpio_led_init.  We just need to toggle OUT via the SIO XOR alias.
    ldr     r4, =SIO_BASE + SIO_GPIO_OUT_XOR
    ldr     r5, =LED_PIN_BIT

.Lc1_loop:
    str     r5, [r4]
    @ ~250 ms at 150 MHz (3-cycle inner body, 12.5M iterations)
    ldr     r0, =12500000
1:  subs    r0, #1
    bne     1b
    b       .Lc1_loop

@ ----------------------------------------------------------------------------
@ main (core 0)
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ Standard boot
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

    @ ---- Launch core 1 ---------------------------------------------------
    ldr     r0, =core1_entry                      @ entry (Thumb bit will be ORed)
    ldr     r1, =_core1_stack_top                 @ sp
    ldr     r2, =_ram_vectors                     @ shared vector table
    bl      multicore_launch_core1

    @ ---- Core 0 idle loop: heartbeat over CDC ----------------------------
.Lc0_loop:
    ldr     r0, =prefix_c0
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ ~1 s pause
    ldr     r0, =50000000
1:  subs    r0, #1
    bne     1b
    b       .Lc0_loop

    .include "src/multicore.S"
    .include "src/nvic.S"
