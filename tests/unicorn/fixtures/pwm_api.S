@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ tests/unicorn/fixtures/pwm_api.S
@
@ Tiny fixture exposing pwm.S as a callable library inside the harness.
@ The test driver loads this ELF, looks up the public PWM symbols, sets
@ r0..r2 by hand, sets PC to the entry, and runs until the BX LR returns
@ to the trampoline below.
@
@ Layout (loaded at SRAM_BASE = 0x20000000):
@   word 0   _stack_top                (vector slot 0; populated by linker)
@   word 1   _start + 1                (vector slot 1; populated by linker)
@
@ _start parks at a self-branch loop after setting up LR so any helper
@ called via PC-injection can `bx lr` back to the same loop, where the
@ test harness can detect the stop.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Pull pwm.S in just like the production examples do.
    .include "src/pwm.S"

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
    @ Park here forever; the harness calls into pwm_* with PC injection.
    @ A helper that does `bx lr` will return here if LR == .Lpark + 1.
    .global _park
_park:
.Lpark:
    b       .Lpark

@ ----------------------------------------------------------------------------
@ Reference every public PWM symbol so --gc-sections doesn't drop them.
@ This block is unreachable; the linker keeps each entry alive because the
@ pointer table mentions them.
@ ----------------------------------------------------------------------------
    .section .rodata._keepalive, "a"
    .align 2
    .global _pwm_keepalive
_pwm_keepalive:
    .word pwm_resets_enable
    .word pwm_init
    .word pwm_set_clkdiv
    .word pwm_set_clkdiv_int
    .word pwm_set_wrap
    .word pwm_set_chan_level
    .word pwm_set_both_levels
    .word pwm_set_phase_correct
    .word pwm_set_output_polarity
    .word pwm_set_enabled
    .word pwm_get_counter
    .word pwm_set_counter
    .word pwm_advance_count
    .word pwm_retard_count
    .word pwm_irq_enable
    .word pwm_acknowledge_irq
    .word pwm_set_freq_hz
    .word pwm_set_gpio_function
