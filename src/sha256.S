@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ sha256.S - RP2350 hardware SHA-256 driver (M5-L)
@
@ Public API (AAPCS):
@   sha256_init                                          configure for word-DMA, BSWAP
@   sha256_start                                         arm engine for a new message
@   sha256_write_word(r0=word)                           push one word, blocks on FIFO
@   sha256_write_block(r0=src_64bytes)                   push 16 words
@   sha256_get_digest(r0=dst_32bytes)                    spin SUM_VLD; copy 8 words
@   sha256_compute(r0=msg, r1=len_bytes, r2=digest_dst)  full convenience: pad + push + read
@
@ Padding rules (firmware-side):
@   - append 0x80
@   - zero-pad until total length mod 64 == 56
@   - append 8 bytes: original message length in BITS, big-endian
@
@ Cycle budget:
@   sha256_write_word (FIFO ready): 4 cycles  (ldr CSR, tst, str WDATA)
@   sha256_compute("abc"):          ~80 cycles overhead + ~64 cycles hash
@ =============================================================================

    .include "sha256.inc"
    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ -----------------------------------------------------------------------------
@ sha256_init - deassert RESETS, set DMA_SIZE = word and BSWAP = 1 so the
@   engine treats little-endian-store words as big-endian SHA-256 input.
@ -----------------------------------------------------------------------------
    .section .text.sha256_init, "ax"
    .thumb_func
    .global  sha256_init
sha256_init:
    movs    r1, #1
    lsls    r1, #RESETS_sha256
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]

    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b

    @ CSR = DMA_SIZE_WORD | BSWAP
    ldr     r0, =SHA256_BASE
    movs    r1, #(SHA256_CSR_DMA_SIZE_WORD | SHA256_CSR_BSWAP)
    str     r1, [r0, #SHA256_CSR]
    bx      lr

@ -----------------------------------------------------------------------------
@ sha256_start - assert CSR.START and wait for it to self-clear.
@ -----------------------------------------------------------------------------
    .section .text.sha256_start, "ax"
    .thumb_func
    .global  sha256_start
sha256_start:
    ldr     r3, =SHA256_BASE
    ldr     r0, [r3, #SHA256_CSR]
    orrs    r0, #SHA256_CSR_START
    str     r0, [r3, #SHA256_CSR]
1:  ldr     r0, [r3, #SHA256_CSR]
    tst     r0, #SHA256_CSR_START
    bne     1b
    bx      lr

@ -----------------------------------------------------------------------------
@ sha256_write_word(r0 = word)
@   Spin on CSR.WDATA_READY then store one word to WDATA.
@ -----------------------------------------------------------------------------
    .section .text.sha256_write_word, "ax"
    .thumb_func
    .global  sha256_write_word
sha256_write_word:
    ldr     r3, =SHA256_BASE
1:  ldr     r2, [r3, #SHA256_CSR]
    tst     r2, #SHA256_CSR_WDATA_READY
    beq     1b
    str     r0, [r3, #SHA256_WDATA]
    bx      lr

@ -----------------------------------------------------------------------------
@ sha256_write_block(r0 = src)
@   Push 16 words from *src into WDATA.
@ -----------------------------------------------------------------------------
    .section .text.sha256_write_block, "ax"
    .thumb_func
    .global  sha256_write_block
sha256_write_block:
    push    {r4, r5, lr}
    mov     r4, r0
    movs    r5, #16
    ldr     r3, =SHA256_BASE
1:  ldr     r2, [r3, #SHA256_CSR]
    tst     r2, #SHA256_CSR_WDATA_READY
    beq     1b
    ldr     r0, [r4], #4
    str     r0, [r3, #SHA256_WDATA]
    subs    r5, #1
    bne     1b
    pop     {r4, r5, pc}

@ -----------------------------------------------------------------------------
@ sha256_get_digest(r0 = dst)
@   Spin on SUM_VLD then copy 8 words into *dst.
@ -----------------------------------------------------------------------------
    .section .text.sha256_get_digest, "ax"
    .thumb_func
    .global  sha256_get_digest
sha256_get_digest:
    ldr     r3, =SHA256_BASE
1:  ldr     r2, [r3, #SHA256_CSR]
    tst     r2, #SHA256_CSR_SUM_VLD
    beq     1b
    ldr     r1, [r3, #SHA256_SUM0]
    str     r1, [r0, #0]
    ldr     r1, [r3, #SHA256_SUM1]
    str     r1, [r0, #4]
    ldr     r1, [r3, #SHA256_SUM2]
    str     r1, [r0, #8]
    ldr     r1, [r3, #SHA256_SUM3]
    str     r1, [r0, #12]
    ldr     r1, [r3, #SHA256_SUM4]
    str     r1, [r0, #16]
    ldr     r1, [r3, #SHA256_SUM5]
    str     r1, [r0, #20]
    ldr     r1, [r3, #SHA256_SUM6]
    str     r1, [r0, #24]
    ldr     r1, [r3, #SHA256_SUM7]
    str     r1, [r0, #28]
    bx      lr

@ -----------------------------------------------------------------------------
@ sha256_compute(r0 = msg, r1 = len_bytes, r2 = digest_dst)
@   Hash a message of arbitrary byte length.  Uses a small stack buffer for
@   the final (padded) block so we don't allocate static state.
@
@   Strategy: feed full 64-byte blocks straight from the input, then build the
@   final padded block(s) on the stack and feed them.  If the residue+0x80
@   doesn't fit in 56 bytes we emit two padded blocks.
@ -----------------------------------------------------------------------------
    .section .text.sha256_compute, "ax"
    .thumb_func
    .global  sha256_compute
sha256_compute:
    push    {r4, r5, r6, r7, r8, lr}
    sub     sp, #128                @ two scratch blocks max

    mov     r4, r0                  @ r4 = msg pointer
    mov     r5, r1                  @ r5 = remaining bytes
    mov     r6, r2                  @ r6 = digest_dst
    mov     r8, r1                  @ r8 = original length (bytes)

    bl      sha256_start

    @ ---- Feed full 64-byte blocks ----------------------------------------
2:  cmp     r5, #64
    blo     3f
    mov     r0, r4
    bl      sha256_write_block
    adds    r4, #64
    subs    r5, #64
    b       2b

    @ ---- Build padded block(s) on the stack ------------------------------
3:  mov     r7, sp                  @ r7 = scratch (128 bytes)
    @ zero scratch
    movs    r0, #0
    movs    r1, #128
4:  strb    r0, [r7, r1]
    subs    r1, #1
    bge     4b

    @ copy residue
    movs    r0, #0
5:  cmp     r0, r5
    bge     6f
    ldrb    r1, [r4, r0]
    strb    r1, [r7, r0]
    adds    r0, #1
    b       5b

6:  @ append 0x80 at offset r5
    movs    r1, #0x80
    strb    r1, [r7, r5]

    @ length in BITS, big-endian, in the last 8 bytes of the padded region
    @ residue+1 <= 56 ? single block : two blocks
    adds    r0, r5, #1              @ bytes used (residue + 0x80)
    cmp     r0, #56
    bls     7f
    @ two blocks: length goes at offset 128-8 = 120
    movs    r3, #120
    movs    r1, #2                  @ block count
    b       8f
7:  movs    r3, #56                 @ length at offset 56
    movs    r1, #1                  @ single block
8:
    @ Write big-endian 64-bit length (bits = bytes * 8)
    @ length_lo32 = (original_len << 3), length_hi32 = (original_len >> 29)
    mov     r0, r8
    lsls    r2, r0, #3              @ r2 = lo32 of bit-count
    lsrs    r0, r0, #29             @ r0 = hi32 of bit-count

    @ big-endian byte order for hi word
    strb    r0, [r7, r3]            @ MSB
    lsrs    r0, #8
    adds    r3, #1
    strb    r0, [r7, r3]
    lsrs    r0, #8
    adds    r3, #1
    strb    r0, [r7, r3]
    lsrs    r0, #8
    adds    r3, #1
    strb    r0, [r7, r3]
    @ big-endian for lo word
    lsrs    r0, r2, #24
    adds    r3, #1
    strb    r0, [r7, r3]
    lsrs    r0, r2, #16
    adds    r3, #1
    strb    r0, [r7, r3]
    lsrs    r0, r2, #8
    adds    r3, #1
    strb    r0, [r7, r3]
    adds    r3, #1
    strb    r2, [r7, r3]

    @ Feed r1 blocks from scratch
9:  mov     r0, r7
    push    {r1}
    bl      sha256_write_block
    pop     {r1}
    adds    r7, #64
    subs    r1, #1
    bne     9b

    @ Read out digest
    mov     r0, r6
    bl      sha256_get_digest

    add     sp, #128
    pop     {r4, r5, r6, r7, r8, pc}
