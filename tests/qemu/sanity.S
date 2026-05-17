@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ sanity.S - "the test infrastructure can run a Thumb program" check.
@
@ Runs on QEMU's mps2-an505 (Cortex-M33).  Uses ARM semihosting:
@   - SYS_WRITE0 (op 0x04) prints a NUL-terminated string
@   - SYS_EXIT   (op 0x18) terminates with a status code
@
@ The semihosting transport on Cortex-M is `bkpt 0xab`:
@   r0 = operation number, r1 = pointer to argument block (or value).
@
@ QEMU returns SYS_EXIT's status to the host process, so a failing test
@ can exit non-zero without writing any output - the test runner is happy
@ to consume just the exit code.  We still print "ok\n" so a human
@ inspecting `-nographic` output sees a sign of life.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ SYS_WRITE0, 0x04
    @ SYS_EXIT_EXTENDED (0x20) takes a {reason, exit_code} block in r1.
    @ Plain SYS_EXIT (0x18) on QEMU's mps2-an505 always reports exit code
    @ as 1 for ApplicationExit (it doesn't read the second word), so we
    @ use the extended variant which honours our exit_code = 0.
    .equ SYS_EXIT_EXTENDED, 0x20
    .equ ADP_Stopped_ApplicationExit, 0x20026

@ ----------------------------------------------------------------- vectors
    .section .vectors, "ax"
    .align   2
    .global _vectors
_vectors:
    .word _stack_top        @  0  initial SP
    .word _start + 1        @  1  reset
    .word _hang  + 1        @  2  NMI
    .word _hang  + 1        @  3  HardFault
    .word _hang  + 1        @  4  MemManage
    .word _hang  + 1        @  5  BusFault
    .word _hang  + 1        @  6  UsageFault
    .word _hang  + 1        @  7  SecureFault
    .word 0
    .word 0
    .word 0
    .word _hang  + 1        @ 11  SVCall
    .word _hang  + 1        @ 12  DebugMon
    .word 0
    .word _hang  + 1        @ 14  PendSV
    .word _hang  + 1        @ 15  SysTick

@ ----------------------------------------------------------------- rodata
    .section .rodata, "a"
ok_msg:
    .asciz "ok\n"

@ ----------------------------------------------------------------- text
    .section .text, "ax"
    .thumb_func
    .global _start
_start:
    @ SYS_WRITE0: r0 = op, r1 = pointer to NUL-terminated string
    movs    r0, #SYS_WRITE0
    ldr     r1, =ok_msg
    bkpt    0xab

    @ SYS_EXIT_EXTENDED: r1 = pointer to {reason, exit_code} block.
    @ reason = 0x20026 (ApplicationExit) tells the host we exited cleanly;
    @ exit_code = 0 propagates to the QEMU host process exit status.
    movs    r0, #SYS_EXIT_EXTENDED
    ldr     r1, =exit_block
    bkpt    0xab

    @ Should never get here, but be defensive in case semihosting is off
    .thumb_func
_hang:
    b       _hang

    .align 2
exit_block:
    .word ADP_Stopped_ApplicationExit
    .word 0                 @ exit status = 0
