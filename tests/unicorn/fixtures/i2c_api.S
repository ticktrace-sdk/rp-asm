@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ tests/unicorn/fixtures/i2c_api.S
@
@ Tiny fixture exposing src/i2c.S as a callable library inside the harness.
@ Mirrors tests/unicorn/fixtures/pwm_api.S - the test driver loads this ELF,
@ looks up the public I2C symbols, sets r0..r3 by hand, sets PC to the
@ entry, and runs until the BX LR returns to the trampoline below.
@
@ We pull in src/gpio.S as well so i2c_set_pins's gpio_set_function /
@ gpio_pull_up references resolve at link time.  GPIO writes are visible
@ via sim.writes for the test that exercises i2c_set_pins.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/gpio.S"
    .include "src/i2c.S"

    .section .vectors, "ax"
    .align 2
    .global  _vectors
_vectors:
    .word _stack_top
    .word _start + 1

    .section .text._start, "ax"
    .thumb_func
    .global _start
_start:
    @ Park here forever; the harness calls into i2c_* with PC injection.
    .global _park
_park:
.Lpark:
    b       .Lpark

@ ----------------------------------------------------------------------------
@ Reference every public I2C symbol so --gc-sections doesn't drop them.
@ ----------------------------------------------------------------------------
    .section .rodata._keepalive, "a"
    .align 2
    .global _i2c_keepalive
_i2c_keepalive:
    .word i2c_init
    .word i2c_deinit
    .word i2c_set_baudrate
    .word i2c_set_slave_mode
    .word i2c_write_blocking
    .word i2c_read_blocking
    .word i2c_set_pins
    .word i2c_set_irqs_enabled
    .word i2c_clear_irq
    .word i2c_set_dma_enabled
    .word i2c_get_status
