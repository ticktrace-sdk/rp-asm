@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ systick.inc - ARMv8-M SysTick + NVIC register definitions (M3-B)
@
@ SysTick lives in the System Control Space (SCS), 0xE000E010-0xE000E01C.
@ Cortex-M33 (RP2350) wires the external reference into the SysTick mux to
@ "clk_sys / 8" (Raspberry Pi datasheet sec 3.6 - on RP2350 the alternate
@ source is clk_sys / 8 rather than a per-core ref tick).
@
@ References: ARMv8-M ARM B11.1 (System Control Space), RP2350 sec 3.6.
@
@ -----------------------------------------------------------------------------
@ SysTick register map:
@   0xE000E010  SYST_CSR     control/status
@                  [0]   ENABLE     1 = counter enabled
@                  [1]   TICKINT    1 = generate SysTick exception on wrap
@                  [2]   CLKSOURCE  1 = processor clock (clk_sys),
@                                   0 = external reference (clk_sys / 8 on RP2350)
@                  [16]  COUNTFLAG  RO; set when counter wraps; cleared on read
@   0xE000E014  SYST_RVR     reload value (24 bits)
@   0xE000E018  SYST_CVR     current value (24 bits, write-any-value clears)
@   0xE000E01C  SYST_CALIB   calibration (RO)
@
@ -----------------------------------------------------------------------------
@ NVIC register map (ARMv8-M, identical to v6/v7-M layout):
@   0xE000E100  NVIC_ISER0   interrupt set-enable, IRQ 0..31
@   0xE000E180  NVIC_ICER0   interrupt clear-enable
@   0xE000E200  NVIC_ISPR0   interrupt set-pending
@   0xE000E280  NVIC_ICPR0   interrupt clear-pending
@   0xE000E300  NVIC_IABR0   active-bit (RO)
@   0xE000E400  NVIC_IPR0    interrupt priority (8-bit per IRQ, but only
@                            the high N bits implemented; M33 = 4 bits)
@ Each register array spans 32 IRQs/word; RP2350 has 51 NVIC lines so we
@ touch ISER0/ISER1, ICER0/ICER1, IPR0..IPR12.
@
@ Vector table layout (already in startup.S at _vectors):
@   indices 0..15 are system vectors; external IRQ N lives at index 16+N.
@ =============================================================================

@ ----- SysTick ---------------------------------------------------------------
    .equ SYST_CSR,              0xE000E010
    .equ SYST_RVR,              0xE000E014
    .equ SYST_CVR,              0xE000E018
    .equ SYST_CALIB,            0xE000E01C

    .equ SYST_CSR_ENABLE,       (1 << 0)
    .equ SYST_CSR_TICKINT,      (1 << 1)
    .equ SYST_CSR_CLKSOURCE,    (1 << 2)
    .equ SYST_CSR_COUNTFLAG,    (1 << 16)

@ ----- NVIC ------------------------------------------------------------------
    .equ NVIC_ISER_BASE,        0xE000E100
    .equ NVIC_ICER_BASE,        0xE000E180
    .equ NVIC_ISPR_BASE,        0xE000E200
    .equ NVIC_ICPR_BASE,        0xE000E280
    .equ NVIC_IPR_BASE,         0xE000E400

@ Vector table is in SRAM (writable) at the address held in SCB_VTOR.
@ External IRQ vectors begin at offset 16*4 = 0x40.
    .equ NVIC_VECTOR_IRQ_OFFSET, 0x40
