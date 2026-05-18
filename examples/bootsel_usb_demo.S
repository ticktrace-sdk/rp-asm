@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/bootsel_usb_demo.S - exercise rom_reset_to_bootsel.
@
@ The point of this demo is to make re-flashing the Pico 2 hands-free:
@ no more "unplug, hold BOOTSEL, replug".  Two host-side triggers are
@ supported, both ultimately calling bootrom rom_reset_usb_boot:
@
@   1. Implicit (1200-baud trick).  When the host issues a CDC
@      SET_LINE_CODING with dwDTERate == 1200 the USB stack itself
@      (see src/usb.S) calls rom_reset_to_bootsel and the device
@      re-enumerates as RPI-RP2.  Matches the convention used by
@      tinygo, picotool, and the Arduino-mbed core; trigger from any
@      shell with:
@           stty -F /dev/ttyACM0 1200
@
@   2. Explicit ('b' on the wire).  Typing 'b' or 'B' over the open
@      CDC connection invokes rom_reset_to_bootsel directly from this
@      demo's main loop.  Useful when stty isn't easy to reach.
@
@ The banner is gated on the CDC DTR rising edge (cdc_dtr in usb.S)
@ rather than a one-shot after usb_configured - the host's terminal
@ program attaches a beat after enumeration so a banner printed at
@ enum time gets clocked out before the terminal sees it.  Repeating
@ the banner periodically also doesn't work because the EP1 IN ring
@ fills before any host opens the port and deadlocks the next
@ cdc_puts; see memory/feedback_cdc_banner.md.
@
@ Note: this demo does NOT touch the BOOTRAM region at 0x400E0000.
@ Per RP2350 datasheet section 4.3, that 1 KiB SRAM is bootrom-owned
@ (it holds the resident partition table, XIP setup callback, and ROM
@ API scratch) and the datasheet explicitly recommends against using
@ it for application storage.  See include/bootram.inc.
@
@ Verify (Linux):
@   minicom -D /dev/ttyACM0 -b 115200    # see banner on first connect
@   <type 'b'>                            # device reboots into BOOTSEL
@      -> RPI-RP2 mass-storage drive appears, ready for a new UF2
@   - or -
@   stty -F /dev/ttyACM0 1200             # same reboot via 1200 baud
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .section .rodata.bootsel_demo, "a"
banner_uart:    .asciz "ticktrace M7 - bootsel demo (rom_reset_to_bootsel)\r\n"
banner_cdc:     .asciz "ticktrace bootsel demo. Send 'b' or open at 1200 baud to enter BOOTSEL.\r\n"

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

    @ Wait for CDC DTR rising edge before printing.  See header note for
    @ why "one-shot on usb_configured" and "periodic reprint" patterns
    @ both fail.
    movs    r5, #0                                  @ r5 = last seen DTR

.Lbanner_loop:
    bl      gpio_led_toggle                         @ heartbeat
    ldr     r0, =cdc_dtr
    ldr     r4, [r0]
    cmp     r4, r5
    beq     .Lpark_pre
    movs    r5, r4
    cmp     r4, #0
    beq     .Lpark_pre                              @ falling edge - nothing

    ldr     r0, =banner_cdc
    bl      cdc_puts
    b       .Lloop

.Lpark_pre:
    ldr     r2, =375000
1:  subs    r2, #1
    bne     1b
    b       .Lbanner_loop

@ ---- Interactive loop -------------------------------------------------------
.Lloop:
    bl      cdc_available
    cbz     r0, .Lpark
1:  bl      cdc_getc
    cmp     r0, #0
    blt     .Lpark
    cmp     r0, #'b'
    beq     .Lreboot
    cmp     r0, #'B'
    beq     .Lreboot
    bl      cdc_putc                                @ echo other bytes
    bl      cdc_available
    cbz     r0, .Lpark
    b       1b

.Lreboot:
    bl      rom_reset_to_bootsel
    b       .                                       @ unreachable

.Lpark:
    bl      gpio_led_toggle
    ldr     r2, =375000
2:  subs    r2, #1
    bne     2b
    b       .Lloop

    .include "src/nvic.S"
