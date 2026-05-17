@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ Fixture exposing src/sched.S + src/nvic.S as a callable library for T1.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/sched.S"
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

    .section .rodata._keepalive, "a"
    .align 2
    .global _sched_keepalive
_sched_keepalive:
    .word sched_init
    .word task_create
    .word task_post
    .word task_post_n
    .word task_clear
    .word sched_run
    .word critical_enter
    .word critical_exit
    .word critical_enter_basepri
    .word critical_exit_basepri
    .word nvic_enable_irq
    .word nvic_install_handler
