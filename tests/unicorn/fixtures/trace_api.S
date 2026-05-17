@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ Fixture exposing src/trace.S as a callable library for T1.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/trace.S"

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
    .global _trace_keepalive
_trace_keepalive:
    .word dwt_init
    .word dwt_cycles_read
    .word dwt_cycles_reset
    .word dwt_cycles_since
    .word itm_init
    .word itm_putc
    .word itm_puts
    .word itm_putw
    .word tpiu_init_swo
    .word etm_init_simple
    .word etm_disable
    .word trace_init
