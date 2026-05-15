@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ sched_stats.S - per-task DWT cycle accounting on top of src/sched.S.
@
@ Opt-in: call `task_create_traced(id, fn, prio)` instead of `task_create`.
@ Per-task trampolines sample DWT.CYCCNT around the user fn and update
@ per-task counters.  Trampolines live in their own sections; --gc-sections
@ drops them if no example references task_create_traced.
@
@ Each task slot has a 16-byte stats block in `task_stats[]`:
@   +0  fn               user handler address (Thumb bit set)
@   +4  cycles_total     summed busy cycles
@   +8  invocations      number of times the task body has run
@   +12 max_cycles       worst-case single-invocation cycles
@
@ Trampolines are static (8 of them, one per task slot 0..MAX_TASKS-1).
@ They share a body via a macro so the source is compact.
@
@ Public API:
@   task_create_traced(r0=id, r1=fn, r2=prio)    Like task_create, plus tracing
@   task_stats_total(r0=id)        -> r0          Cycles_total
@   task_stats_invocations(r0=id)  -> r0
@   task_stats_max(r0=id)          -> r0
@   task_stats_reset(r0=id)                       Zero counters (NOT fn)
@   task_stats_reset_all                          Zero counters for every slot
@
@ Cycle overhead per traced invocation (relative to bare task_create):
@   - 2 ldr to fetch CYCCNT before + after  (~4 cycles)
@   - 1 blx through the fn pointer          (~2 cycles)
@   - 5 stores + 2 reads to update stats    (~14 cycles)
@   Total: ~25 cycles per task body, plus the body's own runtime.
@
@   This is the entire price you pay for "where are my cycles going."
@ =============================================================================

    .include "sched.inc"
    .include "trace.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ task_stats[] — 16 bytes per slot, MAX_TASKS slots, in .data so initial
@ values are well-defined (all zeros).  Place in .data not .bss because
@ the v0.1 startup doesn't zero .bss; .data is loaded directly into SRAM
@ by the bootrom UF2 loader.
@ ----------------------------------------------------------------------------
    .equ STATS_OFF_FN,       0
    .equ STATS_OFF_TOTAL,    4
    .equ STATS_OFF_INVOC,    8
    .equ STATS_OFF_MAX,      12
    .equ STATS_STRIDE,       16

    .section .data.task_stats, "aw"
    .align 2
    .global task_stats
task_stats:
    .rept MAX_TASKS
    .word 0                            @ fn
    .word 0                            @ cycles_total
    .word 0                            @ invocations
    .word 0                            @ max_cycles
    .endr

@ ----------------------------------------------------------------------------
@ Macro: emit a single trampoline for task slot \id.
@   Each trampoline:
@     1. Reads DWT_CYCCNT (t0).
@     2. Loads fn from task_stats[id].fn and calls it.
@     3. Reads DWT_CYCCNT (t1), computes delta.
@     4. Updates cycles_total, invocations, max_cycles.
@   r4 holds the stats-slot base pointer through the call; r5 holds t0.
@   AAPCS: we push {r4, r5, lr}; the user fn must follow AAPCS.
@ ----------------------------------------------------------------------------
    .macro M_TASK_TRAMPOLINE id
    .section .text._task_tramp_\id, "ax"
    .thumb_func
    .global _task_tramp_\id
_task_tramp_\id:
    push    {r4, r5, lr}
    ldr     r4, =task_stats + (\id * STATS_STRIDE)
    ldr     r0, =DWT_BASE + DWT_CYCCNT
    ldr     r5, [r0]                   @ t0
    ldr     r0, [r4, #STATS_OFF_FN]    @ user fn (Thumb-encoded)
    blx     r0
    ldr     r0, =DWT_BASE + DWT_CYCCNT
    ldr     r1, [r0]                   @ t1
    subs    r1, r1, r5                 @ delta
    @ cycles_total += delta
    ldr     r2, [r4, #STATS_OFF_TOTAL]
    add     r2, r2, r1
    str     r2, [r4, #STATS_OFF_TOTAL]
    @ invocations += 1
    ldr     r2, [r4, #STATS_OFF_INVOC]
    adds    r2, #1
    str     r2, [r4, #STATS_OFF_INVOC]
    @ max_cycles = max(max_cycles, delta)
    ldr     r2, [r4, #STATS_OFF_MAX]
    cmp     r1, r2
    bls     1f
    str     r1, [r4, #STATS_OFF_MAX]
1:  pop     {r4, r5, pc}
    .endm

    M_TASK_TRAMPOLINE 0
    M_TASK_TRAMPOLINE 1
    M_TASK_TRAMPOLINE 2
    M_TASK_TRAMPOLINE 3
    M_TASK_TRAMPOLINE 4
    M_TASK_TRAMPOLINE 5
    M_TASK_TRAMPOLINE 6
    M_TASK_TRAMPOLINE 7

@ ----------------------------------------------------------------------------
@ Look-up table of trampoline addresses (Thumb-encoded).  task_create_traced
@ indexes into this to find the right trampoline for the given task id.
@ ----------------------------------------------------------------------------
    .section .rodata.tramp_table, "a"
    .align 2
tramp_table:
    .word _task_tramp_0 + 1
    .word _task_tramp_1 + 1
    .word _task_tramp_2 + 1
    .word _task_tramp_3 + 1
    .word _task_tramp_4 + 1
    .word _task_tramp_5 + 1
    .word _task_tramp_6 + 1
    .word _task_tramp_7 + 1

@ ----------------------------------------------------------------------------
@ task_create_traced(id, fn, prio)
@   1. Store fn into task_stats[id].fn (with Thumb bit set).
@   2. Look up the trampoline for this id.
@   3. Call task_create(id, trampoline, prio).
@ ----------------------------------------------------------------------------
    .section .text.task_create_traced, "ax"
    .thumb_func
    .global  task_create_traced
task_create_traced:
    push    {r4, lr}
    @ Stash fn (with Thumb bit set) into task_stats[id].fn
    ldr     r3, =task_stats
    movs    r4, #STATS_STRIDE
    muls    r4, r4, r0                 @ r4 = id * 16
    add     r3, r3, r4
    orr     r1, r1, #1
    str     r1, [r3, #STATS_OFF_FN]

    @ r1 = trampoline[id]
    ldr     r3, =tramp_table
    ldr     r1, [r3, r0, lsl #2]

    @ Tail through task_create
    bl      task_create
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ Stats getters — each takes r0 = id, returns the field in r0.
@ ----------------------------------------------------------------------------
    .section .text.task_stats_total, "ax"
    .thumb_func
    .global  task_stats_total
task_stats_total:
    ldr     r1, =task_stats
    movs    r2, #STATS_STRIDE
    muls    r2, r2, r0
    add     r1, r1, r2
    ldr     r0, [r1, #STATS_OFF_TOTAL]
    bx      lr

    .section .text.task_stats_invocations, "ax"
    .thumb_func
    .global  task_stats_invocations
task_stats_invocations:
    ldr     r1, =task_stats
    movs    r2, #STATS_STRIDE
    muls    r2, r2, r0
    add     r1, r1, r2
    ldr     r0, [r1, #STATS_OFF_INVOC]
    bx      lr

    .section .text.task_stats_max, "ax"
    .thumb_func
    .global  task_stats_max
task_stats_max:
    ldr     r1, =task_stats
    movs    r2, #STATS_STRIDE
    muls    r2, r2, r0
    add     r1, r1, r2
    ldr     r0, [r1, #STATS_OFF_MAX]
    bx      lr

@ ----------------------------------------------------------------------------
@ task_stats_reset(id) - zero counters but preserve fn.
@ ----------------------------------------------------------------------------
    .section .text.task_stats_reset, "ax"
    .thumb_func
    .global  task_stats_reset
task_stats_reset:
    ldr     r1, =task_stats
    movs    r2, #STATS_STRIDE
    muls    r2, r2, r0
    add     r1, r1, r2
    movs    r3, #0
    str     r3, [r1, #STATS_OFF_TOTAL]
    str     r3, [r1, #STATS_OFF_INVOC]
    str     r3, [r1, #STATS_OFF_MAX]
    bx      lr

@ ----------------------------------------------------------------------------
@ task_stats_reset_all - zero every slot's counters (preserves fn).
@ ----------------------------------------------------------------------------
    .section .text.task_stats_reset_all, "ax"
    .thumb_func
    .global  task_stats_reset_all
task_stats_reset_all:
    ldr     r0, =task_stats
    movs    r1, #MAX_TASKS
    movs    r2, #0
1:  str     r2, [r0, #STATS_OFF_TOTAL]
    str     r2, [r0, #STATS_OFF_INVOC]
    str     r2, [r0, #STATS_OFF_MAX]
    adds    r0, #STATS_STRIDE
    subs    r1, #1
    bne     1b
    bx      lr
