@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/usb_cdc_echo_demo.S - USB CDC-ACM echo (M4-H).
@
@ Brings up the clocks (so clk_usb = 48 MHz), the USB controller, and the
@ CDC-ACM stack.  Once the host has enumerated the device as /dev/ttyACM0
@ (Linux/macOS) or COMx (Windows), bytes the host writes are echoed back.
@
@ Build:   make build/usb_cdc_echo_demo.uf2
@ Flash:   BOOTSEL + drop UF2 onto the RP2350 mass-storage device.
@ Verify (Linux):
@           dmesg | tail   -> expect "cdc_acm 1-...: ttyACM0: USB ACM device"
@           stty -F /dev/ttyACM0 raw -echo
@           cat /dev/ttyACM0 &
@           echo "hello" > /dev/ttyACM0   -> "hello" prints on the terminal
@
@ Architecture:
@   - main installs usb_device_isr at NVIC vector 14, brings up the USB
@     controller, then sits in a wfi loop.
@   - usb_device_isr handles BUS_RESET, SETUP_REQ (enumeration), and
@     BUFF_STATUS (bulk EP completion).
@   - On EP1 OUT completion the ISR drains the bytes into cdc_rx_buf.  We
@     poll cdc_available from the main loop (between wfi wakes) and echo
@     each byte via cdc_putc.  cdc_putc kicks the EP1 IN buffer.
@
@ Cycle budget is dominated by the SETUP-handler enumeration (~1000 cycles
@ per request, ~10 requests per enumeration); after enumeration the steady
@ state is ~150 cycles per echoed byte.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .section .rodata.banner_usb, "a"
banner_usb:
    .asciz "ticktrace M4-H - USB CDC-ACM echo demo\r\n"

@ ----------------------------------------------------------------------------
@ main - bring up clocks, USB, then loop echoing RX bytes back.
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

    @ ---- LED + UART for status output -------------------------------------
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner_usb
    bl      uart0_puts

    @ ---- USB controller bring-up ------------------------------------------
    bl      usb_device_init

    @ ---- Install ISR at NVIC vector 14 ------------------------------------
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler

    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ ---- Main loop: echo any RX bytes back via cdc_putc -------------------
    @ wfi parks until any peripheral irq fires; we wake on USB events
    @ (SETUP / BUS_RESET / BUFF_STATUS) and re-check the RX ring.
.Lloop:
    bl      cdc_available
    cbz     r0, .Lpark
1:  bl      cdc_getc
    cmp     r0, #0
    blt     .Lpark
    bl      cdc_putc
    bl      cdc_available
    cbz     r0, .Lpark
    b       1b

.Lpark:
    wfi
    b       .Lloop

@ ---- Bundle the NVIC helper into this image so we don't depend on it being
@      in DRIVER_SRC (nvic.S is M3-B; example pattern: .include into the
@      example .o the bits we need).
    .include "src/nvic.S"
