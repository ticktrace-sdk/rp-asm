@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ boot2.S - RP2040 second-stage bootloader (256-byte passthrough).
@
@ Datasheet ref: RP2040 sec 2.8 (Boot Sequence).
@
@ Memory layout in flash:
@   0x10000000  +-----------------------+
@               |  BOOT2 (252 bytes)    |  <- this code, padded with zeros
@               +-----------------------+
@   0x100000FC  |  CRC32-MPEG2 trailer  |  (4 bytes; patched by tools/boot2_crc.py)
@               +-----------------------+
@   0x10000100  |  app vector table     |  <- linked here by link/flash.ld
@               +-----------------------+
@
@ Bootrom flow (RP2040 sec 2.8.1.3):
@   1. Bootrom configures XIP_SSI for slow 0x03 "Read Data" mode at
@      SCK = clk_ref / 6 (~2 MHz).  Flash is now XIP-readable, slowly.
@   2. Bootrom copies bytes 0..255 from flash 0x10000000 to SRAM 0x20041F00.
@   3. Bootrom validates the CRC32-MPEG2 over bytes 0..251 against
@      the 32-bit word at bytes 252..255.
@   4. On match, bootrom sets PC = 0x20041F01 (Thumb bit) and jumps.
@
@ This minimal BOOT2 stub does NOT re-tune the QSPI for Quad I/O fast
@ reads - the app runs from XIP at the bootrom's default speed.  A
@ Quad-I/O optimized BOOT2 will land in a follow-up commit (similar to
@ pico-sdk's boot2_w25q080.S).  For now we just hand control to the app.
@
@ Position independence: the bootrom executes us from SRAM at 0x20041F00,
@ but the linker emits us at flash 0x10000000.  PC-relative literal loads
@ (`ldr Rd, =const`) are position-independent because the literal pool
@ sits in the same section at a fixed relative offset.  Only absolute
@ branches would break - we use `bx` for the handoff, which works for
@ any 32-bit target.
@
@ Image size: 24 bytes of code + 8 bytes of literal pool = 32 bytes.
@ The .boot2 output section is sized to exactly 256 bytes by the linker;
@ the gap from end-of-code to offset 252 is zero-filled by `= 0x00` on
@ the BOOT2 memory region.
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

    .section .boot2, "ax"
    .align   2
    .global  _boot2
    .thumb_func
_boot2:
    @ ---- 1. VTOR <- app vector table address ------------------------------
    @ Without this, any interrupt during early app execution would vector
    @ into the bootrom's ROM table at 0x00000000 (where the bootrom leaves
    @ VTOR by default).  Set it now so the app's vector table at flash
    @ 0x10000100 takes over before startup.S has a chance to copy and
    @ re-VTOR to _ram_vectors.
    ldr     r0, =SCB_VTOR
    ldr     r1, =0x10000100                 @ app vector table base
    str     r1, [r0]

    @ ---- 2. Load MSP from vec[0], reset handler from vec[1] ---------------
    @ ARMv6-M narrow LDM always writes back; r1 gets advanced to vec[2] but
    @ we don't reference it again.
    ldmia   r1!, {r0, r2}                   @ r0 = stack top, r2 = reset
    msr     msp, r0                         @ MSP <- stack top
    bx      r2                              @ jump (Thumb bit set in vec[1])
