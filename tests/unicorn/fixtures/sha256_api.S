@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ Fixture exposing src/sha256.S as a callable library for the T1 harness.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/sha256.S"

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
    .global _sha256_keepalive
_sha256_keepalive:
    .word sha256_init
    .word sha256_start
    .word sha256_write_word
    .word sha256_write_block
    .word sha256_get_digest
    .word sha256_compute
