@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ pio.inc - RP2350 PIO (Programmable IO) — 3 blocks of 4 state machines.
@
@ Bases: PIO0=0x50200000, PIO1=0x50300000, PIO2=0x50400000
@ RESETS bits: pio0=11, pio1=12, pio2=13
@ =============================================================================

    .equ PIO0_BASE,   0x50200000
    .equ PIO1_BASE,   0x50300000
    .equ PIO2_BASE,   0x50400000

    .equ RESETS_pio0, 11
    .equ RESETS_pio1, 12
    .equ RESETS_pio2, 13

    @ Global per-PIO registers
    .equ PIO_CTRL,            0x000
    .equ PIO_FSTAT,           0x004
    .equ PIO_FDEBUG,          0x008
    .equ PIO_FLEVEL,          0x00C
    .equ PIO_TXF0,            0x010
    .equ PIO_TXF1,            0x014
    .equ PIO_TXF2,            0x018
    .equ PIO_TXF3,            0x01C
    .equ PIO_RXF0,            0x020
    .equ PIO_RXF1,            0x024
    .equ PIO_RXF2,            0x028
    .equ PIO_RXF3,            0x02C
    .equ PIO_IRQ,             0x030
    .equ PIO_INSTR_MEM0,      0x048

    @ CTRL bits
    .equ PIO_CTRL_SM_ENABLE_SHIFT,   0
    .equ PIO_CTRL_SM_RESTART_SHIFT,  4
    .equ PIO_CTRL_CLKDIV_RESTART_SHIFT, 8

    @ FSTAT bits
    .equ PIO_FSTAT_TX_FULL_SHIFT,   0
    .equ PIO_FSTAT_TX_EMPTY_SHIFT,  8
    .equ PIO_FSTAT_RX_FULL_SHIFT,  16
    .equ PIO_FSTAT_RX_EMPTY_SHIFT, 24

    @ Per-SM block starts at +0x0C8, stride 0x18
    .equ PIO_SM0_CLKDIV,      0x0C8
    .equ PIO_SM0_EXECCTRL,    0x0CC
    .equ PIO_SM0_SHIFTCTRL,   0x0D0
    .equ PIO_SM0_ADDR,        0x0D4
    .equ PIO_SM0_INSTR,       0x0D8
    .equ PIO_SM0_PINCTRL,     0x0DC
    .equ PIO_SM_STRIDE,       0x018

    @ PINCTRL bit fields
    .equ PIO_PINCTRL_OUT_BASE_SHIFT,     0     @ 5 bits
    .equ PIO_PINCTRL_SET_BASE_SHIFT,     5     @ 5 bits
    .equ PIO_PINCTRL_SIDESET_BASE_SHIFT, 10    @ 5 bits
    .equ PIO_PINCTRL_IN_BASE_SHIFT,      15    @ 5 bits
    .equ PIO_PINCTRL_OUT_COUNT_SHIFT,    20    @ 6 bits
    .equ PIO_PINCTRL_SET_COUNT_SHIFT,    26    @ 3 bits
    .equ PIO_PINCTRL_SIDESET_COUNT_SHIFT, 29   @ 3 bits

    @ EXECCTRL key fields
    .equ PIO_EXECCTRL_WRAP_BOTTOM_SHIFT, 7
    .equ PIO_EXECCTRL_WRAP_TOP_SHIFT,    12

    @ GPIO function codes
    .equ GPIO_FUNC_PIO0, 6
    .equ GPIO_FUNC_PIO1, 7
    .equ GPIO_FUNC_PIO2, 8
