@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ EXPECT: arith ok
@ =============================================================================
@ isa_arith.S - exercise basic Thumb-2 arithmetic + conditional execution.
@
@ If the assembler / QEMU emit-or-decode is correct, this prints "arith ok\n"
@ and exits 0.  Otherwise stays in the wrong branch and reports failure.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ SYS_WRITE0,         0x04
    .equ SYS_EXIT_EXTENDED,  0x20
    .equ ADP_AppExit,        0x20026

    .section .vectors, "ax"
    .word _stack_top
    .word _start + 1
    .word _hang + 1
    .word _hang + 1

    .section .rodata, "a"
ok_msg:   .asciz "arith ok\n"
fail_msg: .asciz "arith fail\n"

    .section .text, "ax"
    .thumb_func
    .global _start
_start:
    @ Test 1: muls / adds / subs flag behaviour
    movs    r0, #7
    movs    r1, #6
    muls    r0, r1, r0          @ r0 = 42
    cmp     r0, #42
    bne     .Lfail

    @ Test 2: conditional move via IT block.  Inside an IT block the S
    @ suffix is forbidden in Thumb-2, so we use plain moveq / addeq.
    movs    r2, #1
    cmp     r2, #1
    itt     eq
    moveq   r3, #0xAA
    addeq   r3, r3, #0x11       @ r3 = 0xBB iff EQ taken both times
    cmp     r3, #0xBB
    bne     .Lfail

    @ Test 3: bitfield extract (UBFX) - ARMv7-M
    ldr     r4, =0xDEADBEEF
    ubfx    r5, r4, #4, #8      @ r5 = bits [11:4] = 0xEE
    cmp     r5, #0xEE
    bne     .Lfail

    movs    r0, #SYS_WRITE0
    ldr     r1, =ok_msg
    bkpt    0xab
    b       .Lexit

.Lfail:
    movs    r0, #SYS_WRITE0
    ldr     r1, =fail_msg
    bkpt    0xab
    @ Fall through and exit non-zero
    movs    r0, #SYS_EXIT_EXTENDED
    ldr     r1, =fail_block
    bkpt    0xab

.Lexit:
    movs    r0, #SYS_EXIT_EXTENDED
    ldr     r1, =ok_block
    bkpt    0xab
.Lspin:
    b       .Lspin

    .thumb_func
_hang:
    b _hang

    .align 2
ok_block:   .word ADP_AppExit
            .word 0
fail_block: .word ADP_AppExit
            .word 1

