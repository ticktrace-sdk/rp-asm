# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""GPIO-specific mocks + helpers for the T1 Unicorn harness.

Importable module - never modify ``harness.py`` itself, per M3 conflict-
avoidance ground rules (PWM/DMA/TIMER agents are touching different
mocks).

Two flavours of helpers:

  1.  ``call_function(sim, name, *args)`` - drive the harness through one
      AAPCS call into a function loaded from the ELF and return the
      observed writes for that call.  Useful for unit-testing each
      gpio_* entry point in isolation.

  2.  ``mock_gpio_in(sim, pin, value)`` / ``mock_gpio_irq_pending(...)`` -
      register synthetic SIO_GPIO_IN values / IO_BANK0 INTR nibble values
      so polling code in firmware sees the line state we want.
"""

from __future__ import annotations

import struct
from typing import List, Optional

# Address-map constants
SIO_BASE = 0xD0000000
SIO_GPIO_IN = SIO_BASE + 0x004
SIO_GPIO_HI_IN = SIO_BASE + 0x008
SIO_GPIO_OUT_SET = SIO_BASE + 0x018
SIO_GPIO_OUT_CLR = SIO_BASE + 0x020
SIO_GPIO_OUT_XOR = SIO_BASE + 0x028
SIO_GPIO_OE_SET = SIO_BASE + 0x038
SIO_GPIO_OE_CLR = SIO_BASE + 0x040
SIO_GPIO_HI_OUT_SET = SIO_BASE + 0x058
SIO_GPIO_HI_OUT_CLR = SIO_BASE + 0x060
SIO_GPIO_HI_OUT_XOR = SIO_BASE + 0x068
SIO_GPIO_HI_OE_SET = SIO_BASE + 0x078
SIO_GPIO_HI_OE_CLR = SIO_BASE + 0x080

IO_BANK0_BASE = 0x40028000
IO_BANK0_INTR0 = 0x230
IO_BANK0_PROC0_INTE0 = 0x248

IO_QSPI_BASE = 0x40030000

PADS_BANK0_BASE = 0x40038000
PADS_QSPI_BASE = 0x40040000

ATOMIC_XOR = 0x1000
ATOMIC_SET = 0x2000
ATOMIC_CLR = 0x3000

# Function selects
GPIO_FUNC_XIP = 0
GPIO_FUNC_SPI = 1
GPIO_FUNC_UART = 2
GPIO_FUNC_I2C = 3
GPIO_FUNC_PWM = 4
GPIO_FUNC_SIO = 5
GPIO_FUNC_PIO0 = 6
GPIO_FUNC_PIO1 = 7
GPIO_FUNC_PIO2 = 8
GPIO_FUNC_GPCK = 9
GPIO_FUNC_USB = 10
GPIO_FUNC_UART_AUX = 11
GPIO_FUNC_NULL = 31

# Pad-register fields
PADS_SLEWFAST = 1 << 0
PADS_SCHMITT = 1 << 1
PADS_PDE = 1 << 2
PADS_PUE = 1 << 3
PADS_DRIVE_LSB = 4
PADS_DRIVE_MASK = 0x30
PADS_IE = 1 << 6
PADS_OD = 1 << 7
PADS_ISO = 1 << 8
PADS_ISO_OD = PADS_ISO | PADS_OD

# IRQ event encoding
GPIO_IRQ_LEVEL_LOW = 1
GPIO_IRQ_LEVEL_HIGH = 2
GPIO_IRQ_EDGE_LOW = 4
GPIO_IRQ_EDGE_HIGH = 8

# Magic LR sentinel that signals "fall out of the call".  We pick a value
# that lives in mapped SRAM so the BX LR doesn't immediately fault, then
# the per-PC hook stops the simulator when it lands on it.
RETURN_SENTINEL = 0x20000000


def io_bank0_ctrl(pin: int) -> int:
    return IO_BANK0_BASE + 4 + pin * 8


def pads_bank0_pad(pin: int) -> int:
    return PADS_BANK0_BASE + 4 + pin * 4


def pads_bank0_pad_set(pin: int) -> int:
    return PADS_BANK0_BASE + ATOMIC_SET + 4 + pin * 4


def pads_bank0_pad_clr(pin: int) -> int:
    return PADS_BANK0_BASE + ATOMIC_CLR + 4 + pin * 4


def proc0_inte_for(pin: int) -> int:
    """IO_BANK0_PROC0_INTE0 + (pin // 8) * 4 (plain alias)."""
    return IO_BANK0_BASE + IO_BANK0_PROC0_INTE0 + (pin // 8) * 4


def proc0_inte_set_for(pin: int) -> int:
    return IO_BANK0_BASE + ATOMIC_SET + IO_BANK0_PROC0_INTE0 + (pin // 8) * 4


def proc0_inte_clr_for(pin: int) -> int:
    return IO_BANK0_BASE + ATOMIC_CLR + IO_BANK0_PROC0_INTE0 + (pin // 8) * 4


def intr_for(pin: int) -> int:
    return IO_BANK0_BASE + IO_BANK0_INTR0 + (pin // 8) * 4


def irq_nibble_shift(pin: int) -> int:
    """Bit position of the events nibble for pin within its INTR/INTE word."""
    return (pin % 8) * 4


def call_function(sim, addr: int, args: list) -> None:
    """Set up an AAPCS call into ``addr`` and run until BX LR returns.

    args is a list of up to 4 32-bit integers placed in r0..r3.  The
    function must follow standard AAPCS: callee may save r4..r11 but
    must restore them before BX LR.

    On return, sim.writes contains every MMIO transaction emitted during
    the call.  The caller is expected to slice writes_before vs
    writes_after to diff.
    """
    from unicorn.arm_const import (
        UC_ARM_REG_R0,
        UC_ARM_REG_R1,
        UC_ARM_REG_R2,
        UC_ARM_REG_R3,
        UC_ARM_REG_LR,
        UC_ARM_REG_PC,
    )

    arg_regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
    for i, v in enumerate(args[:4]):
        sim.uc.reg_write(arg_regs[i], v & 0xFFFFFFFF)

    # LR sentinel - run until PC == this address.  We use SRAM_BASE which
    # holds the initial-SP word; harmless to land there since we'll stop
    # immediately via the PC hook.
    sim.uc.reg_write(UC_ARM_REG_LR, RETURN_SENTINEL | 1)  # Thumb bit
    sim.uc.reg_write(UC_ARM_REG_PC, addr | 1)

    # Run until BX LR drops us at the sentinel
    sim._stop_at_pc = RETURN_SENTINEL & ~1
    sim._stop_after_steps = 200  # plenty for any single gpio_* function
    sim._stopped_reason = None
    start = sim.uc.reg_read(UC_ARM_REG_PC) | 1
    sim.uc.emu_start(start, until=0, count=0)
    if sim._stopped_reason == "step_cap":
        raise TimeoutError(
            f"call_function({addr:#x}) ran past 200 steps "
            f"without reaching the LR sentinel - infinite loop?")


def writes_during(sim, before_count: int) -> list:
    """Return MmioEvent list of writes appended since ``before_count``."""
    return sim.writes[before_count:]


def mock_gpio_in(sim, pin: int, value: int) -> None:
    """Make subsequent reads of SIO_GPIO_IN[pin] return ``value`` (0 or 1).

    The state survives until you call this again with the same pin.
    """
    if pin < 32:
        addr = SIO_GPIO_IN
    else:
        addr = SIO_GPIO_HI_IN
        pin = pin - 32

    cur = sim.peek32(addr)
    if value:
        cur |= (1 << pin)
    else:
        cur &= ~(1 << pin)
    sim.poke32(addr, cur & 0xFFFFFFFF)


def mock_gpio_irq_pending(sim, pin: int, events: int) -> None:
    """Make subsequent reads of IO_BANK0 INTR[pin/8] include ``events``
    in the (pin%8)*4 nibble."""
    addr = intr_for(pin)
    shift = irq_nibble_shift(pin)
    cur = sim.peek32(addr)
    cur |= ((events & 0xF) << shift)
    sim.poke32(addr, cur & 0xFFFFFFFF)


def mock_proc0_ints(sim, pin: int, events: int) -> None:
    """Same as mock_gpio_irq_pending but for the masked INTS array
    (offset 0x278) - what a polling loop in firmware will read."""
    INTS0 = 0x278
    addr = IO_BANK0_BASE + INTS0 + (pin // 8) * 4
    shift = irq_nibble_shift(pin)
    cur = sim.peek32(addr)
    cur |= ((events & 0xF) << shift)
    sim.poke32(addr, cur & 0xFFFFFFFF)
