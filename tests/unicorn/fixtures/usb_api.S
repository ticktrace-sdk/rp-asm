@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ tests/unicorn/fixtures/usb_api.S
@
@ Tiny fixture exposing usb.S as a callable library inside the harness.
@ The test driver loads this ELF, looks up the public USB symbols, sets
@ r0..r2 by hand, sets PC to the entry, and runs until the BX LR returns
@ to the trampoline below.
@
@ Layout (loaded at SRAM_BASE = 0x20000000):
@   word 0   _stack_top                (vector slot 0; populated by linker)
@   word 1   _start + 1                (vector slot 1; populated by linker)
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Pull usb.S in just like the production examples do.
    .include "src/usb.S"

    .section .vectors, "ax"
    .align 2
    .global _vectors
_vectors:
    .word _stack_top
    .word _start + 1

    .section .text._start, "ax"
    .thumb_func
    .global _start
_start:
    @ Park here forever; the harness calls into usb_* with PC injection.
    @ A helper that does `bx lr` (or pop {pc}) returns here when LR == _park.
    .global _park
_park:
.Lpark:
    b       .Lpark

@ ----------------------------------------------------------------------------
@ Stubs for external symbols usb.S calls into (other than the usb_* ones
@ defined in usb.S itself). usb.S calls rom_reset_to_bootsel after a USB
@ reset packet; the test harness never drives that path, so a `bx lr` stub
@ satisfies the linker without affecting test behaviour.
@ ----------------------------------------------------------------------------
    .section .text.rom_reset_to_bootsel, "ax"
    .thumb_func
    .global rom_reset_to_bootsel
rom_reset_to_bootsel:
    bx      lr

@ ----------------------------------------------------------------------------
@ Reference every public USB symbol so --gc-sections doesn't drop them.
@ ----------------------------------------------------------------------------
    .section .rodata._keepalive, "a"
    .align 2
    .global _usb_keepalive
_usb_keepalive:
    .word usb_device_init
    .word usb_device_isr
    .word usb_send_zlp
    .word usb_ep_send
    .word usb_ep_receive_arm
    .word usb_get_received
    .word usb_ep_buf_ctrl_addr
    .word _usb_send_descriptor
    .word _cdc_try_flush_tx
    .word cdc_putc
    .word cdc_puts
    .word cdc_available
    .word cdc_getc
