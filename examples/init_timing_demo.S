@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/init_timing_demo.S - measure where init time is spent.
@
@ Snapshots the DWT CYCCNT at each major init phase plus the four USB
@ enumeration phases instrumented in src/usb.S (BUS_RESET, first SETUP,
@ SET_CONFIGURATION, DTR rising).  After DTR rises we dump the full
@ report over both UART0 (115200 8N1) and the CDC ttyACM.
@
@ The report prints raw cycle counts and per-phase deltas.  Two clock
@ rates are in play:
@   - T_MAIN .. T_PLL_DONE  run at ROSC (~6.5 MHz post-bootrom)
@   - T_PLL_DONE .. T_DTR   run at PLL_SYS (150 MHz)
@ So divide cycles-from-T_PLL_DONE by 150 for microseconds.
@
@ Build:   make build/init_timing_demo_flash.uf2
@ Verify:  flash + connect via gtkterm/minicom; report prints on first
@          DTR rising edge (port open).
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

@ ---- Phase timestamps (DWT CYCCNT snapshots) -------------------------------
    .section .bss.phase, "aw", %nobits
    .align   2
phase_t_main:       .word 0
phase_t_xosc:       .word 0
phase_t_pll:        .word 0
phase_t_clocks:     .word 0
phase_t_tick_wd:    .word 0
phase_t_gpio_uart:  .word 0
phase_t_usb_init:   .word 0
phase_t_irq_armed:  .word 0

    .align   2
dec_buf:            .space 12

    .section .rodata.timing, "a"
banner_uart:    .asciz "rp-asm init-timing demo. Booting...\r\n"
banner_cdc:     .asciz "=== rp-asm init timing report ===\r\n"
hdr_phase:      .asciz "phase             cycles_since_main   delta_cycles\r\n"
sep:            .asciz "----------------- ------------------- ------------\r\n"
crlf:           .asciz "\r\n"
spaces16:       .asciz "                "      @ pad helper (16 spaces)
note:           .asciz "(ROSC ~6.5 MHz before t_pll, PLL_SYS 150 MHz after)\r\n"

n_main:        .asciz "t_main            "
n_xosc:        .asciz "t_xosc            "
n_pll:         .asciz "t_pll             "
n_clocks:      .asciz "t_clocks          "
n_tick_wd:     .asciz "t_tick_wd         "
n_gpio_uart:   .asciz "t_gpio_uart       "
n_usb_init:    .asciz "t_usb_init        "
n_irq_armed:   .asciz "t_irq_armed       "
n_bus_reset:   .asciz "t_bus_reset       "
n_first_setup: .asciz "t_first_setup     "
n_configured:  .asciz "t_configured      "
n_dtr:         .asciz "t_dtr             "

@ ----------------------------------------------------------------------------
@ _put_dec(value) - print 32-bit unsigned decimal via uart0_puts AND cdc_puts.
@ Clobbers r0-r5.  Uses dec_buf.
@ ----------------------------------------------------------------------------
    .section .text._put_dec, "ax"
    .thumb_func
_put_dec:
    push    {r4, r5, lr}
    ldr     r5, =dec_buf + 11
    movs    r4, #0
    strb    r4, [r5]                              @ NUL terminate
    mov     r4, r0
    cbnz    r4, 1f
    @ Zero special case
    subs    r5, #1
    movs    r0, #'0'
    strb    r0, [r5]
    b       2f
1:
    movs    r1, #10
    udiv    r2, r4, r1
    mls     r3, r2, r1, r4                        @ r3 = r4 - r2*10
    adds    r3, #'0'
    subs    r5, #1
    strb    r3, [r5]
    mov     r4, r2
    cmp     r4, #0
    bne     1b
2:
    mov     r0, r5
    bl      uart0_puts
    mov     r0, r5
    bl      cdc_puts
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ _put_pad(value) - print value decimal then pad with spaces so the column
@ is right-aligned at 19 chars (matching the header "cycles_since_main").
@ ----------------------------------------------------------------------------
    .section .text._put_pad, "ax"
    .thumb_func
_put_pad:
    push    {r4, r5, lr}
    @ Count digits first
    mov     r4, r0
    movs    r5, #1                                @ at least one digit
    cbz     r4, .Lpad_print
1:  mov     r1, r4
    movs    r2, #10
    udiv    r4, r1, r2
    cbz     r4, .Lpad_print_loop_done
    adds    r5, #1
    b       1b
.Lpad_print_loop_done:
    @ r5 = #digits in original value.  Want 19 chars total minus r5 spaces.
    @ But uart_puts needs a string; just emit spaces individually.
.Lpad_print:
    mov     r4, r0                                @ stash value
    movs    r1, #19
    subs    r1, r1, r5                            @ pad count
3:  cmp     r1, #0
    ble     4f
    movs    r0, #' '
    bl      uart0_putc
    movs    r0, #' '
    bl      cdc_putc
    subs    r1, #1
    b       3b
4:  mov     r0, r4
    bl      _put_dec
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ _print_row(name_ptr, abs_cycles, delta_cycles)
@ ----------------------------------------------------------------------------
    .section .text._print_row, "ax"
    .thumb_func
_print_row:
    push    {r4, r5, r6, lr}
    mov     r4, r0                                @ name
    mov     r5, r1                                @ abs
    mov     r6, r2                                @ delta
    mov     r0, r4
    bl      uart0_puts
    mov     r0, r4
    bl      cdc_puts
    mov     r0, r5
    bl      _put_pad
    movs    r0, #' '
    bl      uart0_putc
    movs    r0, #' '
    bl      cdc_putc
    movs    r0, #' '
    bl      uart0_putc
    movs    r0, #' '
    bl      cdc_putc
    mov     r0, r6
    bl      _put_dec
    ldr     r0, =crlf
    bl      uart0_puts
    ldr     r0, =crlf
    bl      cdc_puts
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ Tiny inline DWT_CYCCNT readers.  Macro-free for clarity at each phase.
@ ----------------------------------------------------------------------------
.macro SNAP target
    movw    r0, #0x1004
    movt    r0, #0xE000
    ldr     r0, [r0]
    ldr     r1, =\target
    str     r0, [r1]
.endm

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ DWT must be enabled before CYCCNT is meaningful.  This is the first
    @ thing we do in main; the bootrom-handoff cycles before this are
    @ unobservable from here.
    bl      dwt_init
    SNAP    phase_t_main

    bl      xosc_init
    SNAP    phase_t_xosc

    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    SNAP    phase_t_pll

    bl      clocks_init
    SNAP    phase_t_clocks

    bl      tick_init
    bl      watchdog_disable
    SNAP    phase_t_tick_wd

    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    SNAP    phase_t_gpio_uart

    ldr     r0, =banner_uart
    bl      uart0_puts

    bl      usb_device_init
    SNAP    phase_t_usb_init

    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq
    SNAP    phase_t_irq_armed

    @ Wait for DTR rising.  Toggle the LED while waiting so we can tell
    @ the firmware is alive vs hung.
.Lwait_dtr:
    ldr     r0, =usb_t_dtr
    ldr     r1, [r0]
    cbnz    r1, .Lreport
    bl      gpio_led_toggle
    ldr     r2, =375000
1:  subs    r2, #1
    bne     1b
    b       .Lwait_dtr

@ ---- Report -----------------------------------------------------------------
.Lreport:
    ldr     r0, =crlf
    bl      uart0_puts
    ldr     r0, =banner_cdc
    bl      uart0_puts
    ldr     r0, =banner_cdc
    bl      cdc_puts
    ldr     r0, =hdr_phase
    bl      uart0_puts
    ldr     r0, =hdr_phase
    bl      cdc_puts
    ldr     r0, =sep
    bl      uart0_puts
    ldr     r0, =sep
    bl      cdc_puts

    @ Helper: each row is (name, abs, delta-from-prev).  We pass abs and
    @ delta in r1, r2 to _print_row.

    @ t_main: abs=0, delta=0 (it's our origin)
    ldr     r0, =n_main
    ldr     r1, =phase_t_main
    ldr     r1, [r1]
    movs    r2, #0
    bl      _print_row

    @ t_xosc
    ldr     r0, =n_xosc
    ldr     r1, =phase_t_xosc
    ldr     r1, [r1]
    ldr     r3, =phase_t_main
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_pll
    ldr     r0, =n_pll
    ldr     r1, =phase_t_pll
    ldr     r1, [r1]
    ldr     r3, =phase_t_xosc
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_clocks
    ldr     r0, =n_clocks
    ldr     r1, =phase_t_clocks
    ldr     r1, [r1]
    ldr     r3, =phase_t_pll
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_tick_wd
    ldr     r0, =n_tick_wd
    ldr     r1, =phase_t_tick_wd
    ldr     r1, [r1]
    ldr     r3, =phase_t_clocks
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_gpio_uart
    ldr     r0, =n_gpio_uart
    ldr     r1, =phase_t_gpio_uart
    ldr     r1, [r1]
    ldr     r3, =phase_t_tick_wd
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_usb_init
    ldr     r0, =n_usb_init
    ldr     r1, =phase_t_usb_init
    ldr     r1, [r1]
    ldr     r3, =phase_t_gpio_uart
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_irq_armed
    ldr     r0, =n_irq_armed
    ldr     r1, =phase_t_irq_armed
    ldr     r1, [r1]
    ldr     r3, =phase_t_usb_init
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_bus_reset (from usb.S)
    ldr     r0, =n_bus_reset
    ldr     r1, =usb_t_bus_reset
    ldr     r1, [r1]
    ldr     r3, =phase_t_irq_armed
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_first_setup
    ldr     r0, =n_first_setup
    ldr     r1, =usb_t_first_setup
    ldr     r1, [r1]
    ldr     r3, =usb_t_bus_reset
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_configured
    ldr     r0, =n_configured
    ldr     r1, =usb_t_configured
    ldr     r1, [r1]
    ldr     r3, =usb_t_first_setup
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    @ t_dtr
    ldr     r0, =n_dtr
    ldr     r1, =usb_t_dtr
    ldr     r1, [r1]
    ldr     r3, =usb_t_configured
    ldr     r3, [r3]
    sub     r2, r1, r3
    bl      _print_row

    ldr     r0, =note
    bl      uart0_puts
    ldr     r0, =note
    bl      cdc_puts

    @ Park forever, LED slow blink.
.Lpark:
    bl      gpio_led_toggle
    ldr     r2, =5000000
1:  subs    r2, #1
    bne     1b
    b       .Lpark

    .include "src/nvic.S"
