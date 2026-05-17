# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""UART mocks for the Unicorn T1 harness (M4-E).

Wraps both UART0 and UART1 PL011 instances.  Reuses the harness's standard
hook plumbing.  Two helpers:

    mock_uart_tx_capture(sim, idx) -> list
        Captures every byte written to UART<idx>_DR.  Returns the list it
        appends to so a test can poll transmitted bytes incrementally.
        Also reports FR.TXFF=0 (always writable) for the matching FR offset.

    mock_uart_rx_data(sim, idx, bytes_seq)
        Feeds bytes into UART<idx>_DR reads.  Each read of DR pops the next
        byte from the sequence; FR is patched so RXFE is 0 while bytes
        remain, and back to 1 (RX FIFO empty) when exhausted.

Constants mirror include/uart.inc; keep in sync.
"""

from __future__ import annotations

from typing import List, Sequence

# Bases (from include/uart.inc / rp2350.inc)
UART0_BASE = 0x40070000
UART1_BASE = 0x40078000
UART_INST_STRIDE = UART1_BASE - UART0_BASE

# Register offsets
UART_DR = 0x00
UART_RSR = 0x04
UART_FR = 0x18
UART_ILPR = 0x20
UART_IBRD = 0x24
UART_FBRD = 0x28
UART_LCR_H = 0x2C
UART_CR = 0x30
UART_IFLS = 0x34
UART_IMSC = 0x38
UART_RIS = 0x3C
UART_MIS = 0x40
UART_ICR = 0x44
UART_DMACR = 0x48

# FR bits
UART_FR_CTS = 1 << 0
UART_FR_BUSY = 1 << 3
UART_FR_RXFE = 1 << 4
UART_FR_TXFF = 1 << 5
UART_FR_RXFF = 1 << 6
UART_FR_TXFE = 1 << 7

# LCR_H bits
UART_LCR_H_BRK = 1 << 0
UART_LCR_H_PEN = 1 << 1
UART_LCR_H_EPS = 1 << 2
UART_LCR_H_STP2 = 1 << 3
UART_LCR_H_FEN = 1 << 4
UART_LCR_H_WLEN_LSB = 5
UART_LCR_H_WLEN_MASK = 3 << 5

# CR bits
UART_CR_UARTEN = 1 << 0
UART_CR_LBE = 1 << 7
UART_CR_TXE = 1 << 8
UART_CR_RXE = 1 << 9
UART_CR_RTSEN = 1 << 14
UART_CR_CTSEN = 1 << 15

# IMSC / RIS / MIS / ICR bits
UART_INT_RIM = 1 << 0
UART_INT_CTSM = 1 << 1
UART_INT_RXIM = 1 << 4
UART_INT_TXIM = 1 << 5
UART_INT_RTIM = 1 << 6

# DMACR bits
UART_DMACR_RXDMAE = 1 << 0
UART_DMACR_TXDMAE = 1 << 1
UART_DMACR_DMAONERR = 1 << 2

# RESETS bits
RESETS_uart0 = 26
RESETS_uart1 = 27

# NVIC IRQ numbers
UART0_IRQ = 33
UART1_IRQ = 34

# Atomic alias offsets (RP2350 standard)
ATOMIC_RW = 0x0000
ATOMIC_XOR = 0x1000
ATOMIC_SET = 0x2000
ATOMIC_CLR = 0x3000


def uart_base(idx: int) -> int:
    """Absolute byte address of UART<idx> register block."""
    if idx not in (0, 1):
        raise ValueError(f"idx must be 0 or 1, got {idx}")
    return UART0_BASE + idx * UART_INST_STRIDE


def uart_writes_to(sim, addr: int, size: int = None) -> List:
    """Return all sim.writes events targeting `addr` (optionally filtered by size)."""
    out = []
    for w in sim.writes:
        if w.addr != addr:
            continue
        if size is not None and w.size != size:
            continue
        out.append(w)
    return out


def mock_uart_tx_capture(sim, idx: int) -> List[int]:
    """Capture every byte written to UART<idx>.DR.  Returns the list."""
    base = uart_base(idx)
    out: List[int] = []

    def fr_read(addr: int, size: int) -> int:
        # Always report TX FIFO empty + not busy so any blocking-tx loop exits.
        return UART_FR_TXFE

    sim.on_read(base + UART_FR, 4, fr_read)

    def dr_write(addr: int, value: int, size: int) -> None:
        offset = addr & 0xFFF
        # DR is at 0x00; cover plain + atomic aliases (0x0000/0x1000/0x2000/0x3000)
        if (addr - base) & 0xFFF == UART_DR or addr == base + UART_DR:
            out.append(value & 0xFF)

    # Cover plain + atomic aliases by hooking the entire 0x4000 window.
    sim.on_write(base, 0x4000, dr_write)
    return out


def mock_uart_rx_data(sim, idx: int, bytes_seq: Sequence[int]) -> None:
    """Feed `bytes_seq` into successive reads of UART<idx>.DR.

    While bytes remain, FR.RXFE reads as 0 (data available); once exhausted,
    FR.RXFE flips back to 1 and DR reads return the last byte (PL011-ish).
    """
    base = uart_base(idx)
    queue = list(bytes_seq)
    state = {"last": 0}

    def fr_read(addr: int, size: int) -> int:
        if queue:
            return UART_FR_TXFE  # RXFE=0, TXFE=1, TXFF=0, BUSY=0
        return UART_FR_TXFE | UART_FR_RXFE

    def dr_read(addr: int, size: int):
        if queue:
            v = queue.pop(0)
            state["last"] = v
            return v
        return state["last"]

    sim.on_read(base + UART_FR, 4, fr_read)
    sim.on_read(base + UART_DR, 4, dr_read)
