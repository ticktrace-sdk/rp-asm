@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ trng.S - RP2350 TRNG driver (M5-J)
@
@ Public API:
@   trng_init                       deassert RESETS, enable random source
@   trng_get_random_word() -> r0    poll TRNG_VALID, read EHR_DATA0; mark
@                                    EHR consumed and re-arm
@   trng_get_random_block(r0=dst, r1=words)
@                                   fetch `words` 32-bit values into *dst
@
@ The CryptoCell EHR holds 192 bits = 6 words. After reading all 6 words,
@ writing 1 to RNG_ICR clears the EHR_VALID flag and the source automatically
@ refills the EHR. We hide that cycle from the caller.
@ =============================================================================

    .include "trng.inc"
    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .text.trng_init, "ax"
    .thumb_func
    .global  trng_init
trng_init:
    movs    r1, #1
    lsls    r1, #RESETS_trng
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b

    ldr     r3, =TRNG_BASE
    @ Mask all interrupts (we poll)
    movs    r0, #0xFF
    str     r0, [r3, #TRNG_RNG_IMR]
    @ CONFIG = ROSC_LENGTH=0 (shortest ring, fastest startup); platform-dependent
    movs    r0, #0
    str     r0, [r3, #TRNG_CONFIG]
    @ Sample count - leave at reset default by writing 0xFFFF (long sample window)
    ldr     r0, =0xFFFF
    str     r0, [r3, #TRNG_SAMPLE_CNT1]
    @ Enable random source
    movs    r0, #1
    str     r0, [r3, #TRNG_RND_SOURCE_ENABLE]
    bx      lr

    .section .text.trng_get_random_word, "ax"
    .thumb_func
    .global  trng_get_random_word
trng_get_random_word:
    ldr     r3, =TRNG_BASE
1:  ldr     r1, [r3, #TRNG_VALID]
    tst     r1, #TRNG_VALID_EHR_VALID
    beq     1b
    ldr     r0, [r3, #TRNG_EHR_DATA0]
    @ The CryptoCell EHR holds 192 bits across 6 registers.  Reading only
    @ EHR_DATA0 leaves the EHR partially-consumed and the ICR-triggered
    @ refill never starts -- subsequent calls see the same word.  Drain
    @ DATA1..DATA5 here too (discarding) so ICR really does re-arm the
    @ source.  We sacrifice 5/6 of the entropy in exchange for caller
    @ simplicity.
    ldr     r1, [r3, #TRNG_EHR_DATA0 +  4]
    ldr     r1, [r3, #TRNG_EHR_DATA0 +  8]
    ldr     r1, [r3, #TRNG_EHR_DATA0 + 12]
    ldr     r1, [r3, #TRNG_EHR_DATA0 + 16]
    ldr     r1, [r3, #TRNG_EHR_DATA0 + 20]
    @ Mark consumed: ICR write clears ISR.EHR_VALID; source refills the EHR.
    movs    r1, #TRNG_ISR_EHR_VALID
    str     r1, [r3, #TRNG_RNG_ICR]
    bx      lr

    .section .text.trng_get_random_block, "ax"
    .thumb_func
    .global  trng_get_random_block
trng_get_random_block:
    @ r0=dst, r1=word_count
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    ldr     r6, =TRNG_BASE
0:  cmp     r5, #0
    beq     9f
    @ Wait for EHR valid
1:  ldr     r0, [r6, #TRNG_VALID]
    tst     r0, #TRNG_VALID_EHR_VALID
    beq     1b
    @ Drain up to 6 words from EHR_DATA0..5, but no more than r5 remaining
    movs    r2, #0                          @ index 0..5
2:  cmp     r2, #6
    beq     3f
    cmp     r5, #0
    beq     3f
    lsls    r3, r2, #2
    add     r3, r3, #TRNG_EHR_DATA0
    ldr     r0, [r6, r3]
    str     r0, [r4], #4
    subs    r5, #1
    adds    r2, #1
    b       2b
3:  @ Acknowledge EHR consumed; source refills
    movs    r0, #TRNG_ISR_EHR_VALID
    str     r0, [r6, #TRNG_RNG_ICR]
    b       0b
9:  pop     {r4, r5, r6, pc}
