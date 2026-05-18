@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ Fixture exposing c_bridge/asm_libc.S + runtime.S to the T1 harness.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "c_bridge/asm_libc.S"
    .include "c_bridge/runtime.S"

    @ The runtime needs __bss_start__/__bss_end__ to bracket a real region.
    @ Provide a fake BSS in .data so the linker resolves them but we control
    @ where they point in the test fixture.
    .section .data.fake_bss, "aw"
    .align 2
    .global __bss_start__
__bss_start__:
    .space 64
    .global __bss_end__
__bss_end__:

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
    .global _libc_keepalive
_libc_keepalive:
    .word memset
    .word memcpy
    .word memcmp
    .word _c_runtime_init
    .word __bss_start__
    .word __bss_end__
