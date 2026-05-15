@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ spsc.inc - Single-producer, single-consumer byte queue.
@
@ Lock-free when used in the SPSC role: one writer of `head` (the producer,
@ typically a hardware ISR) and one writer of `tail` (the consumer, typically
@ a soft task posted by that ISR).  No critical sections required.
@
@ For multi-producer use (two ISRs both pushing), wrap pushes in
@ critical_enter_basepri / critical_exit_basepri.
@
@ Layout (declare a queue with the M_SPSC_BYTE_QUEUE macro below):
@   +0   head    (uint32_t, producer write index)
@   +4   tail    (uint32_t, consumer read index)
@   +8   mask    (uint32_t, size_pow2 - 1)
@   +12  _pad    (uint32_t, reserved; keeps data 8-byte aligned)
@   +16  data    (uint8_t[size_pow2])
@
@ Capacity is size_pow2 - 1 (one slot reserved to distinguish empty from
@ full; standard SPSC trick).
@ =============================================================================

    .equ SPSC_OFF_HEAD,   0
    .equ SPSC_OFF_TAIL,   4
    .equ SPSC_OFF_MASK,   8
    .equ SPSC_OFF_DATA,   16

@ ---------------------------------------------------------------- macro
@ M_SPSC_BYTE_QUEUE <name>, <log2size>
@   Declares a queue in .bss.  log2size must be 2..10 (queue 4..1024).
@   Exports `<name>` as a label pointing at the struct header.
@
@ Example:
@   M_SPSC_BYTE_QUEUE  uart_rx_q, 6      @ 64-byte buffer, 63-byte capacity
@ ---------------------------------------------------------------- macro
    .macro M_SPSC_BYTE_QUEUE name, log2size
    .section .data.\name, "aw"
    .align 2
    .global \name
\name:
    .word 0                            @ head
    .word 0                            @ tail
    .word ((1 << \log2size) - 1)       @ mask
    .word 0                            @ pad
    .space (1 << \log2size)            @ data (zero-initialised)
    .endm
