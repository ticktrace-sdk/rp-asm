@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ fixtures/timer_api.S - test fixture that pins every M3-B public symbol so
@ --gc-sections does not eliminate the ones a particular example never uses.
@
@ Each symbol is referenced from a no-op .Ldispatch table that is itself
@ KEEP'd by the linker via being inside .text (which the qemu.ld / sram.ld
@ scripts both glob into the output).
@
@ Layout matches the smoke.S fixture: SP at top of SRAM, vec[1] = _start.
@ _start is an infinite spin so harness tests can call individual functions
@ via _call() (sets PC + LR sentinel, runs until LR).
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .vectors, "ax"
    .align 2
    .global _vectors
_vectors:
    .word 0x20080000        @ initial SP
    .word _start + 1        @ reset

    .section .text._start, "ax"
    .thumb_func
    .global _start
_start:
1:  b       1b

@ ---- Pull in the source-of-truth driver code ------------------------------
    .include "src/timer.S"
    .include "src/systick.S"
    .include "src/nvic.S"

@ ---- Reference every public symbol so --gc-sections keeps them ------------
    .section .rodata.api_table, "a"
    .align 2
    .global _api_table
_api_table:
    .word timer_init
    .word timer_resets_enable
    .word time_us_64
    .word time_us_32
    .word delay_us
    .word delay_ms
    .word alarm_set
    .word alarm_cancel
    .word alarm_clear_irq
    .word alarm_enable_irq
    .word systick_start_periodic
    .word systick_stop
    .word systick_get_value
    .word nvic_enable_irq
    .word nvic_disable_irq
    .word nvic_set_pending
    .word nvic_clear_pending
    .word nvic_set_priority
    .word nvic_install_handler
