@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/usb_descriptor_only_demo.S - USB controller bring-up + minimal
@                                       enumeration response (M4-H fallback).
@
@ Same usb_device_init + usb_device_isr as the CDC echo demo, but the host-
@ visible behaviour is intentionally minimal: the device responds to the
@ standard SETUP requests for descriptors, then stalls on the
@ SET_CONFIGURATION attempt (since we never wired up any data endpoints).
@
@ This is the "controller bring-up smoke test" path: even though the host
@ won't see /dev/ttyACM0, dmesg will show the device descriptor (with the
@ rp-asm VID/PID), proving the controller, PHY, and SETUP plumbing all
@ work end-to-end.
@
@ Build:   make build/usb_descriptor_only_demo.uf2
@ Verify:  Plug into Linux host, run `lsusb -v -d 2e8a:000a`.  You should
@          see the 18-byte device descriptor with iManufacturer/iProduct/
@          iSerial all present.  `dmesg` will also show
@          "device descriptor read/64, error -71" or similar after the
@          controller stalls on SET_CONFIGURATION; that's the expected
@          behaviour for this fallback.
@
@ Why ship this:
@   The full CDC-ACM echo path is the v0.1 goal, but USB enumeration is the
@   stack of cards that has to fall just right.  This minimal demo isolates
@   "controller + PHY + SETUP machinery work" from "bulk EPs work", so a
@   real-silicon brown-out can be debugged in two steps instead of one.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .section .rodata.banner_usb_d, "a"
banner_usb_d:
    .asciz "rp-asm M4-H - USB descriptor-only demo\r\n"

@ ----------------------------------------------------------------------------
@ main - bring up clocks, USB, install ISR, sleep forever.
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
    ldr     r0, =banner_usb_d
    bl      uart0_puts

    bl      usb_device_init

    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler

    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

.Lloop:
    wfi
    b       .Lloop

    .include "src/nvic.S"
