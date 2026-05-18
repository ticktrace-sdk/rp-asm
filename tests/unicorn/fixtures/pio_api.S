@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ Fixture exposing src/pio.S + src/gpio.S as a callable library for T1.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/pio.S"
    .include "src/gpio.S"

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

    .section .rodata._keepalive, "a"
    .align 2
    .global _pio_keepalive
_pio_keepalive:
    .word pio_init
    .word pio_add_program
    .word pio_sm_set_clkdiv
    .word pio_sm_set_wrap
    .word pio_sm_set_out_pins
    .word pio_sm_set_set_pins
    .word pio_sm_set_enabled
    .word pio_sm_put
    .word pio_sm_get
    .word pio_sm_exec
    .word pio_gpio_init
