@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ Fixture exposing src/tsbl/tsbl_ab.S's pure functions (tsbl_validate,
@ tsbl_ab_select) as a callable library for the T1 harness.
@
@ We .include src/crc32.S directly because tsbl_validate calls into it;
@ and we use a relabelled copy of the relevant pieces of tsbl_ab.S so the
@ fixture doesn't pull in the .tsbl_vectors / .tsbl_image_def sections
@ (which would conflict with the test harness's expectation of .vectors
@ at SRAM_BASE).

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/crc32.S"
    .include "src/tsbl/tsbl_ab.S"

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
    .global _tsbl_ab_keepalive
_tsbl_ab_keepalive:
    .word tsbl_validate
    .word tsbl_ab_select
    .word crc32_compute
