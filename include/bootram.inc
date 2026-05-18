@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ bootram.inc - BOOTRAM bus-endpoint constants (hardware registers only).
@
@ The BOOTRAM bus endpoint at 0x400E0000 hosts two distinct things:
@
@   0x000..0x3FF  1 KiB of SRAM, BOOTROM-OWNED.  Per RP2350 datasheet
@                 section 4.3:
@                   "It is possible to use boot RAM for user-defined
@                    purposes, but this is not recommended, as it may
@                    cause ROM APIs to behave unpredictably.  Calling
@                    into the ROM could modify data stored in boot RAM."
@                 Also:
@                   "Boot RAM is hardwired to permit Secure access only
@                    (Arm) or Machine-mode access only (RISC-V)."
@                 The bootrom stores the resident partition table, XIP
@                 setup callback (formerly boot2), and ROM-API scratch
@                 here.  We do NOT export this region as application
@                 scratch - use main SRAM (0x20000000+) instead.
@
@   0x800+        Hardware registers (WRITE_ONCE0/1, BOOTLOCK_STAT,
@                 BOOTLOCK0..7).  These are application-accessible but
@                 BOOTLOCKn are typically reserved for bootrom use - the
@                 SDK's hardware_boot_lock APIs gate access to them.
@                 WRITE_ONCE0/1 are sticky (set-only-until-reset) flags
@                 used in secure-boot features.
@
@ Reference: RP2350 datasheet section 4.3.1 "List of registers".
@ =============================================================================

    .equ BOOTRAM_BASE,                  0x400E0000
    .equ BOOTRAM_SIZE,                  0x400         @ 1 KiB SRAM region

    @ Hardware registers (offsets from BOOTRAM_BASE).
    .equ BOOTRAM_WRITE_ONCE0_OFFSET,    0x800
    .equ BOOTRAM_WRITE_ONCE1_OFFSET,    0x804
    .equ BOOTRAM_BOOTLOCK_STAT_OFFSET,  0x808
    .equ BOOTRAM_BOOTLOCK0_OFFSET,      0x80c
    .equ BOOTRAM_BOOTLOCK1_OFFSET,      0x810
    .equ BOOTRAM_BOOTLOCK2_OFFSET,      0x814
    .equ BOOTRAM_BOOTLOCK3_OFFSET,      0x818
    .equ BOOTRAM_BOOTLOCK4_OFFSET,      0x81c
    .equ BOOTRAM_BOOTLOCK5_OFFSET,      0x820
    .equ BOOTRAM_BOOTLOCK6_OFFSET,      0x824
    .equ BOOTRAM_BOOTLOCK7_OFFSET,      0x828
