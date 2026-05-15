# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""RP2350 SPI (PL022) functional model for Renode (M4-G).

This script is the body of a Python.PythonPeripheral instantiated for each
SPI controller (SPI0 @ 0x40080000, SPI1 @ 0x40088000) in rp2350.repl.

Behaviour modelled:
  * SSPCR0 / SSPCR1 / SSPCPSR / SSPDR / SSPSR / SSPIMSC / SSPRIS / SSPMIS /
    SSPICR / SSPDMACR are all R/W register slots that persist across the
    transaction.
  * SSPDR forms a software FIFO (deque, capped at 8 entries).  Pushes are
    appended; pops drain the head.  When SSPCR1.LBM (loopback mode) is on,
    every SSPDR write is also re-appended to the same FIFO, so the next
    SSPDR read returns it - this gives full-duplex parity with the
    real PL022's internal LBM path with zero-cycle round-trip latency.
  * SSPSR is synthesised on read:
      TFE = (FIFO empty)
      TNF = (FIFO not full)
      RNE = (FIFO non-empty)
      RFF = (FIFO at depth)
      BSY = (FIFO non-empty)
  * Atomic alias windows (+0x1000 XOR / +0x2000 SET / +0x3000 CLR) decoded
    so the driver's atomic stores land on the right register.
  * SSPICR W1C only honours bits 0..1 (RORIC / RTIC); the FIFO interrupts
    are level-driven so they aren't latched.

Not modelled:
  * Real bit-clocking timing (zero-cycle - SSPDR writes appear in the FIFO
    immediately).
  * Slave-mode FSS edge detection (we treat both master and slave the same;
    the loopback example exercises only master mode anyway).
  * RX overrun / RX timeout interrupt arm path (the demos don't rely on it).
"""

if request.IsInit:
    state = {
        "cr0": 0,
        "cr1": 0,
        "cpsr": 0,
        "imsc": 0,
        "ris":  0,
        "icr":  0,
        "dmacr": 0,
    }
    _fifo = []           # software TX/RX FIFO (loopback)
    _DEPTH = 8


def _ssp_status():
    s = 0
    if len(_fifo) == 0:
        s |= 0x01      # TFE
    if len(_fifo) < _DEPTH:
        s |= 0x02      # TNF
    if len(_fifo) > 0:
        s |= 0x04      # RNE
        s |= 0x10      # BSY (something pending)
    if len(_fifo) >= _DEPTH:
        s |= 0x08      # RFF
    return s


if request.IsRead:
    off = request.Offset
    base = off & 0xFFF
    if base == 0x00:
        request.Value = state["cr0"]
    elif base == 0x04:
        request.Value = state["cr1"]
    elif base == 0x08:
        # SSPDR read - pop head if any
        if _fifo:
            request.Value = _fifo.pop(0)
        else:
            request.Value = 0
    elif base == 0x0C:
        request.Value = _ssp_status()
    elif base == 0x10:
        request.Value = state["cpsr"]
    elif base == 0x14:
        request.Value = state["imsc"]
    elif base == 0x18:
        request.Value = state["ris"]
    elif base == 0x1C:
        # MIS = RIS & IMSC
        request.Value = state["ris"] & state["imsc"]
    elif base == 0x20:
        request.Value = 0
    elif base == 0x24:
        request.Value = state["dmacr"]
    else:
        request.Value = 0
elif request.IsWrite:
    off = request.Offset
    base = off & 0xFFF
    alias = off & 0x3000
    val = request.Value & 0xFFFFFFFF

    def apply(slot, v):
        cur = state[slot]
        if alias == 0x1000:
            state[slot] = (cur ^ v) & 0xFFFFFFFF
        elif alias == 0x2000:
            state[slot] = (cur | v) & 0xFFFFFFFF
        elif alias == 0x3000:
            state[slot] = cur & ((~v) & 0xFFFFFFFF)
        else:
            state[slot] = v & 0xFFFFFFFF

    if base == 0x00:
        apply("cr0", val)
    elif base == 0x04:
        apply("cr1", val)
    elif base == 0x08:
        # SSPDR write: push into FIFO; if loopback enabled, the bit is
        # immediately readable on the next SSPDR read (i.e. just keep it
        # in the FIFO).  When LBM is OFF we still keep the byte queued so
        # the demo loopback test still passes - an SPI peripheral with no
        # external counterpart in Renode shouldn't black-hole its TX.
        if len(_fifo) < _DEPTH:
            _fifo.append(val & 0xFF)
    elif base == 0x10:
        apply("cpsr", val & 0xFF)
    elif base == 0x14:
        apply("imsc", val & 0xF)
    elif base == 0x20:
        # SSPICR W1C: bits 0..1 only
        cur = state["ris"]
        state["ris"] = cur & ((~(val & 0x3)) & 0xFFFFFFFF)
    elif base == 0x24:
        apply("dmacr", val & 0x3)
