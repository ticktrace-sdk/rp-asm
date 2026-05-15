@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ crc32.S - CRC-32 (IEEE 802.3 / gzip / PNG / Ethernet), bit-serial.
@
@ Polynomial: 0xEDB88320 (reflected). Init: 0xFFFFFFFF. XorOut: 0xFFFFFFFF.
@ Matches Go's hash/crc32.ChecksumIEEE and Python's zlib.crc32 byte for byte,
@ and lives twice in the bootloader chain (once in SSBL, once in TSBL) so
@ each stage can validate the next without depending on a service table.
@
@ ~38 bytes of code, ~10 cycles per bit (~80 cycles per byte). A 24 KiB
@ TSBL hashes in ~2 Mcycles ~= 13 ms at 150 MHz - acceptable boot delay.
@ A table-based variant would be ~5x faster but costs 1 KiB of .rodata,
@ which is most of the SSBL's flash budget. Bit-serial is the right
@ trade for a once-per-boot operation.
@
@ AAPCS leaf function: caller saves r0-r3, we preserve r4.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ uint32_t crc32_compute(const uint8_t *buf, uint32_t len);
@   r0 = buffer pointer
@   r1 = byte count
@   returns r0 = CRC32-IEEE of [buf, buf+len)
@   clobbers r2, r3 (caller-save); restores r4
@ ----------------------------------------------------------------------------
    .section .text.crc32_compute, "ax"
    .thumb_func
    .align   2
    .global  crc32_compute
crc32_compute:
    push    {r4, lr}

    @ r2 = CRC state = 0xFFFFFFFF
    movs    r2, #0
    mvns    r2, r2

    @ r4 = polynomial 0xEDB88320 (reflected CRC-32-IEEE)
    movw    r4, #0x8320
    movt    r4, #0xEDB8

    cbz     r1, .Lcrc_done

.Lcrc_byte:
    ldrb    r3, [r0], #1            @ next input byte, post-increment
    eors    r2, r3                  @ fold into low byte of state
    movs    r3, #8                  @ bit counter

.Lcrc_bit:
    lsrs    r2, #1                  @ shift state right; LSB -> C
    bcc     .Lcrc_no_xor            @ if popped 0, no polynomial xor
    eors    r2, r4                  @ otherwise xor with poly
.Lcrc_no_xor:
    subs    r3, #1
    bne     .Lcrc_bit

    subs    r1, #1
    bne     .Lcrc_byte

.Lcrc_done:
    mvns    r0, r2                  @ final xor with 0xFFFFFFFF
    pop     {r4, pc}
