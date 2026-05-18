@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ tests/unicorn/fixtures/uart_api.S
@
@ Fixture exposing src/uart.S as a callable library for the T1 harness.
@ Mirrors fixtures/pwm_api.S - load this ELF, look up a public symbol,
@ set r0..r3 by hand, and run until LR returns to _park.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Pull in the driver under test PLUS its NVIC dependency (uart_set_irq_handler
    @ calls into nvic_install_handler / nvic_enable_irq).
    .include "src/uart.S"
    .include "src/nvic.S"

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
    .global _park
_park:
.Lpark:
    b       .Lpark

@ ----------------------------------------------------------------------------
@ Keepalive table - prevent --gc-sections from dropping public driver symbols.
@ ----------------------------------------------------------------------------
    .section .rodata._keepalive, "a"
    .align 2
    .global _uart_keepalive
_uart_keepalive:
    .word uart_resets_deassert
    .word uart_resets_assert
    .word uart_init
    .word uart_deinit
    .word uart_set_baudrate
    .word uart_set_format
    .word uart_set_hw_flow
    .word uart_set_irqs_enabled
    .word uart_acknowledge_irq
    .word uart_set_dma_enabled
    .word uart_is_writable
    .word uart_is_readable
    .word uart_putc_blocking
    .word uart_puts_blocking
    .word uart_getc_blocking
    .word uart_tx_wait_blocking
    .word uart_set_irq_handler
    .word uart0_init
    .word uart0_putc
    .word uart0_puts
