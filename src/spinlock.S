@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ spinlock.S - RP2350 hardware spinlocks (32 of them in SIO).
@
@ SIO_SPINLOCKn at SIO_BASE + 0x100 + n*4 (n = 0..31).  Each is a single
@ 32-bit register with the protocol:
@   read  : if locked, returns 0; if free, atomically locks and returns
@           (1 << n) - non-zero.
@   write : releases the lock (any value).
@
@ This is the "test-and-set in a single load" hardware spinlock, the
@ canonical way two cores synchronise on shared SRAM.
@
@ Public API:
@   spin_try_lock(n)    -> r0     1 = acquired, 0 = busy
@   spin_lock_blocking(n)         spin until acquired
@   spin_unlock(n)                release
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ SIO_SPINLOCK_BASE, SIO_BASE + 0x100

@ ----------------------------------------------------------------------------
@ spin_try_lock(idx) -> r0 = 0 (busy) or non-zero (acquired)
@ Clobbers: r0-r2.
@ ----------------------------------------------------------------------------
    .section .text.spin_try_lock, "ax"
    .thumb_func
    .global  spin_try_lock
spin_try_lock:
    lsls    r1, r0, #2
    ldr     r2, =SIO_SPINLOCK_BASE
    ldr     r0, [r2, r1]                          @ read locks + sets (HW)
    bx      lr

@ ----------------------------------------------------------------------------
@ spin_lock_blocking(idx) - busy-wait until acquired.  Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.spin_lock_blocking, "ax"
    .thumb_func
    .global  spin_lock_blocking
spin_lock_blocking:
    lsls    r1, r0, #2
    ldr     r2, =SIO_SPINLOCK_BASE
    adds    r3, r2, r1                            @ &SIO_SPINLOCKn
1:  ldr     r0, [r3]
    cmp     r0, #0                                @ cbz only branches forward
    beq     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ spin_unlock(idx) - any write releases.  Clobbers: r0-r2.
@ ----------------------------------------------------------------------------
    .section .text.spin_unlock, "ax"
    .thumb_func
    .global  spin_unlock
spin_unlock:
    lsls    r1, r0, #2
    ldr     r2, =SIO_SPINLOCK_BASE
    movs    r0, #0
    str     r0, [r2, r1]
    bx      lr
