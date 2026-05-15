@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ rp2350.inc - RP2350 register map (subset used by rp-asm v0.1)
@
@ All offsets/bit positions cross-checked against the RP2350 datasheet
@ (Raspberry Pi RP2350 datasheet, rev 0.3, Aug 2024).
@
@ Atomic register aliases (apply to most APB peripherals):
@   +0x0000  normal RW
@   +0x1000  XOR on write
@   +0x2000  bitwise SET on write
@   +0x3000  bitwise CLR on write
@ =============================================================================

    .equ ATOMIC_XOR,  0x1000
    .equ ATOMIC_SET,  0x2000
    .equ ATOMIC_CLR,  0x3000

@ ---- ARMv8-M System Control Block --------------------------------------------
    .equ SCB_VTOR,    0xE000ED08

@ ---- SIO (single-cycle IO, M33-local) ----------------------------------------
    .equ SIO_BASE,           0xD0000000
    .equ SIO_GPIO_OUT,       0x010
    .equ SIO_GPIO_OUT_SET,   0x018
    .equ SIO_GPIO_OUT_CLR,   0x020
    .equ SIO_GPIO_OUT_XOR,   0x028
    .equ SIO_GPIO_OE,        0x030
    .equ SIO_GPIO_OE_SET,    0x038
    .equ SIO_GPIO_OE_CLR,    0x040
    .equ SIO_GPIO_OE_XOR,    0x048

@ ---- RESETS ------------------------------------------------------------------
    .equ RESETS_BASE,        0x40020000
    .equ RESETS_RESET,       0x00
    .equ RESETS_RESET_DONE,  0x08

    @ Bit positions in RESETS_RESET (RP2350 §7.5)
    .equ RESETS_io_bank0,    6
    .equ RESETS_pads_bank0,  9
    .equ RESETS_uart0,       26

@ ---- IO_BANK0 ----------------------------------------------------------------
    .equ IO_BANK0_BASE,      0x40028000
    @ Per-GPIO block is 8 bytes: { STATUS, CTRL }. CTRL = base + 4 + n*8
    .equ IO_BANK0_GPIO_CTRL_STRIDE, 8
    .equ GPIO_FUNC_SIO,      5
    .equ GPIO_FUNC_UART,     2

@ ---- PADS_BANK0 --------------------------------------------------------------
    .equ PADS_BANK0_BASE,    0x40038000
    @ Per-pad register at offset 4 + n*4 (offset 0 is VOLTAGE_SELECT)
    @ Bits: SLEWFAST=0, SCHMITT=1, PDE=2, PUE=3, DRIVE[5:4], IE=6, OD=7, ISO=8
    .equ PADS_BANK0_PAD_STRIDE, 4
    .equ PADS_ISO,           (1 << 8)
    .equ PADS_OD,            (1 << 7)
    .equ PADS_IE,            (1 << 6)

@ ---- UART0 (PL011) -----------------------------------------------------------
    .equ UART0_BASE,         0x40070000
    .equ UART_DR,            0x00
    .equ UART_FR,            0x18
    .equ UART_IBRD,          0x24
    .equ UART_FBRD,          0x28
    .equ UART_LCR_H,         0x2C
    .equ UART_CR,            0x30

    @ UART_FR bits
    .equ UART_FR_TXFF,       (1 << 5)   @ TX FIFO full
    .equ UART_FR_RXFE,       (1 << 4)   @ RX FIFO empty
    .equ UART_FR_BUSY,       (1 << 3)
