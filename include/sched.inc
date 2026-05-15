@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ sched.inc - NVIC-priority kernel (QV-style) for rp-asm
@
@ Each "task" is an NVIC handler.  task_post(id) is one STR to NVIC_ISPR;
@ the CPU services the highest-priority pending task to completion, then
@ tail-chains into the next.  No software dispatcher, no per-task stacks.
@
@ Task slots map to NVIC IRQ lines starting at SCHED_BASE_IRQ.  We pick a
@ range high enough not to collide with RP2350's hardware peripherals
@ (UART0_IRQ=33, I2C1_IRQ=36, ...) but low enough to fit in the NVIC's
@ implemented IRQ count.  RP2350 implements at least 56 NVIC lines per
@ datasheet rev 0.3 §3.2, so 48..55 are safe spare lines.  If a future
@ chip rev gives some of these to peripherals, raise SCHED_BASE_IRQ.
@ =============================================================================

    .equ MAX_TASKS,        8
    .equ SCHED_BASE_IRQ,   48

    @ NVIC banks (Cortex-M33 ARMv8-M, §B3.4)
    .equ NVIC_ISER_BASE,   0xE000E100   @ Interrupt Set-Enable (one bank per 32 IRQs)
    .equ NVIC_ICER_BASE,   0xE000E180
    .equ NVIC_ISPR_BASE,   0xE000E200   @ Set-Pending (this is how task_post works)
    .equ NVIC_ICPR_BASE,   0xE000E280
    .equ NVIC_IPR_BASE,    0xE000E400   @ Priority byte per IRQ (byte-addressed)
    .equ NVIC_STIR,        0xE000EF00   @ Software-trigger alternative

    .equ SCB_VTOR,         0xE000ED08
    .equ SCB_AIRCR,        0xE000ED0C
    .equ SCB_SCR,          0xE000ED10
    .equ SCB_SCR_SEVONPEND, (1 << 4)

@ Task ID aliases — let users say `T_FOO = 0` in their bench instead of
@ hand-tracking numbers.  Define your own .equs in your example/app.
