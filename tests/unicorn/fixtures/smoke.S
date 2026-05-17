@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ smoke.S - smallest possible exerciser for the Unicorn harness.
@
@ Layout (matches what RP2350Sim._set_initial_sp_pc expects):
@   word 0:  initial SP
@   word 1:  reset entry (Thumb bit set)
@   word 2+: spare vectors (we never trigger an exception)
@   .text:   _start writes 0xCAFEBABE to 0xD0000010 (SIO_GPIO_OUT) then halts.
@
@ The harness should observe exactly one MMIO write event:
@   MmioEvent(pc=_start, addr=0xD0000010, value=0xCAFEBABE, size=4, is_write=True)
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .vectors, "ax"
    .align   2
    .global _vectors
_vectors:
    .word 0x20080000        @ initial SP - top of 512 KiB SRAM
    .word _start + 1        @ reset PC, Thumb bit set

    .section .text._start, "ax"
    .thumb_func
    .global _start
_start:
    ldr     r0, =0xD0000010 @ SIO_GPIO_OUT
    ldr     r1, =0xCAFEBABE
    str     r1, [r0]
1:  b       1b              @ self-loop; harness stops via run_until_pc
