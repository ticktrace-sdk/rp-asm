@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ otp.S - RP2350 OTP (One-Time Programmable) read access.
@
@ The OTP block is 8 KiB of one-time-programmed storage holding:
@   - Factory data (CHIPID, RANDID, flash device info, ...)
@   - User-programmable rows (boot config, secure-boot keys, ...)
@
@ Access modes:
@   OTP_DATA_BASE     (0x40130000)  ECC-decoded, halfword per row, stride 4
@   OTP_DATA_RAW_BASE (0x40134000)  Raw 24-bit per row (low 24 of each word)
@
@ This driver is read-only.  Programming OTP requires the bootrom API
@ and is destructive (bits can only flip 0 -> 1 once), so we keep it
@ out of the asm core.
@
@ Public API:
@   otp_read_row(row) -> r0           ECC-decoded 16-bit value (zero-extended)
@   otp_read_raw(row) -> r0           Raw 24-bit value (zero-extended)
@   otp_read_chipid(dst)              writes 4 halfwords (CHIPID0..3) to *dst
@
@ Reference: RP2350 datasheet sec 13.6 (OTP).
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ OTP_DATA_BASE,     0x40130000
    .equ OTP_DATA_RAW_BASE, 0x40134000

    .equ OTP_ROW_CHIPID0,   0
    .equ OTP_ROW_CHIPID1,   1
    .equ OTP_ROW_CHIPID2,   2
    .equ OTP_ROW_CHIPID3,   3

@ ----------------------------------------------------------------------------
@ otp_read_row(row) -> r0
@   r0 = row index (0..2047)
@   Returns 16-bit ECC-decoded value, zero-extended to 32 bits.
@ Clobbers: r0-r1.
@ ----------------------------------------------------------------------------
    .section .text.otp_read_row, "ax"
    .thumb_func
    .global  otp_read_row
otp_read_row:
    ldr     r1, =OTP_DATA_BASE
    ldrh    r0, [r1, r0, lsl #2]
    bx      lr

@ ----------------------------------------------------------------------------
@ otp_read_raw(row) -> r0
@   r0 = row index (0..2047)
@   Returns raw 24-bit value, zero-extended to 32 bits.  Use this if you
@   need the parity/ECC bits or are reading bits that haven't been ECC-
@   protected by the manufacturer.
@ Clobbers: r0-r1.
@ ----------------------------------------------------------------------------
    .section .text.otp_read_raw, "ax"
    .thumb_func
    .global  otp_read_raw
otp_read_raw:
    ldr     r1, =OTP_DATA_RAW_BASE
    ldr     r0, [r1, r0, lsl #2]
    @ The upper 8 bits of each raw word are reserved; mask off.
    movw    r1, #0xFFFF
    movt    r1, #0x00FF
    and     r0, r0, r1
    bx      lr

@ ----------------------------------------------------------------------------
@ otp_read_chipid(dst) - writes 4 halfwords (CHIPID0..3) at *dst.
@   r0 = pointer to 8 bytes of writable memory
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.otp_read_chipid, "ax"
    .thumb_func
    .global  otp_read_chipid
otp_read_chipid:
    ldr     r1, =OTP_DATA_BASE + OTP_ROW_CHIPID0 * 4
    ldrh    r2, [r1, #0]
    strh    r2, [r0, #0]
    ldrh    r2, [r1, #4]
    strh    r2, [r0, #2]
    ldrh    r2, [r1, #8]
    strh    r2, [r0, #4]
    ldrh    r2, [r1, #12]
    strh    r2, [r0, #6]
    bx      lr
