# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""Renode T3 helper notes for the UART (M4-E) tests.

The Renode platform description (rp2350.repl) already maps both UART0 and
UART1 to the upstream UART.PL011 model.  No Python peripheral is needed -
PL011 is a fully-modelled component and supports both blocking-tx, IRQs
(wired to nvic0@33 / nvic0@34), and the standard line-monitor analyzer.

For uart_loopback_demo.S we cross-wire UART0 TX -> UART1 RX and vice versa
inside the .resc using Renode's CharReceived event handlers.  See
tests/renode/uart.resc for the wiring.

This file exists to:
  * document the rp2350.repl mapping for future M4-E maintainers
  * provide a Python helper if the loopback wiring ever needs more
    sophisticated logic (latency injection, frame errors, etc.)

Currently empty of executable code; the .resc is self-contained.
"""

# Address constants (mirror include/uart.inc; useful for ad-hoc debugging
# from the Renode monitor):
UART0_BASE = 0x40070000
UART1_BASE = 0x40078000
UART_DR = 0x00
UART_FR = 0x18
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

UART0_IRQ = 33
UART1_IRQ = 34
