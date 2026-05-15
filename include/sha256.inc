@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ sha256.inc - RP2350 hardware SHA-256 accelerator (datasheet §11)
@
@ The engine consumes 64-byte blocks via the WDATA FIFO and produces a 256-bit
@ digest in SUM0..SUM7.  Firmware is responsible for SHA-256 padding (0x80,
@ zeros, 64-bit length-in-bits).  The hardware does NOT pad.
@ =============================================================================

    .equ SHA256_BASE,         0x400f8000
    .equ RESETS_sha256,       17

    @ Register offsets
    .equ SHA256_CSR,          0x00
    .equ SHA256_WDATA,        0x04
    .equ SHA256_SUM0,         0x08
    .equ SHA256_SUM1,         0x0C
    .equ SHA256_SUM2,         0x10
    .equ SHA256_SUM3,         0x14
    .equ SHA256_SUM4,         0x18
    .equ SHA256_SUM5,         0x1C
    .equ SHA256_SUM6,         0x20
    .equ SHA256_SUM7,         0x24

    @ CSR bits (RP2350 datasheet sec 12.13)
    .equ SHA256_CSR_START,                (1 << 0)
    .equ SHA256_CSR_WDATA_READY,          (1 << 1)
    .equ SHA256_CSR_SUM_VLD,              (1 << 2)
    .equ SHA256_CSR_ERR_WDATA_NOT_RDY,    (1 << 4)
    .equ SHA256_CSR_DMA_SIZE_SHIFT,       8       @ bits [9:8]: 0=byte, 1=half, 2=word
    .equ SHA256_CSR_DMA_SIZE_WORD,        (2 << 8)
    .equ SHA256_CSR_BSWAP,                (1 << 12)

    .equ SHA256_BLOCK_BYTES,  64
    .equ SHA256_BLOCK_WORDS,  16
    .equ SHA256_DIGEST_BYTES, 32
    .equ SHA256_DIGEST_WORDS, 8

    @ DREQ for DMA pacing — RP2350 SHA256 DREQ = 45 (verify datasheet table 6.5.4.1)
    .equ DREQ_SHA256,         45
