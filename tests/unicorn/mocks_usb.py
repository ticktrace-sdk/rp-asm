# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""USB mocks for the RP2350Sim harness (M4-H).

The USB controller lives outside the APB window the harness pre-maps:
  USBCTRL_DPRAM_BASE = 0x50100000   (4 KiB DPRAM)
  USBCTRL_REGS_BASE  = 0x50110000   (controller regs)

Tests must call `map_usb_region(sim)` before exercising the driver, otherwise
the first store traps with UC_ERR_WRITE_UNMAPPED.

The functional layer (mock_usb_setup, mock_usb_buff_status) lets a test
populate the SETUP packet at DPRAM[0..7] and pend a BUFF_STATUS interrupt
so the ISR can be unit-tested in isolation.
"""

from __future__ import annotations

import struct
from typing import Optional


# ---- Bases ------------------------------------------------------------------
USBCTRL_DPRAM_BASE = 0x50100000
USBCTRL_REGS_BASE  = 0x50110000

# ---- DPRAM offsets ----------------------------------------------------------
DPRAM_SETUP_PACKET   = 0x000
DPRAM_EP_CTRL_BASE   = 0x008
DPRAM_EP_BUF_CTRL    = 0x080
DPRAM_EP0_BUF0       = 0x100
DPRAM_EP1_OUT_BUF    = 0x180
DPRAM_EP1_IN_BUF     = 0x1C0

# ---- Register offsets (relative to USBCTRL_REGS_BASE) -----------------------
USB_ADDR_ENDP        = 0x000
USB_MAIN_CTRL        = 0x040
USB_SIE_CTRL         = 0x04C
USB_SIE_STATUS       = 0x050
USB_BUFF_STATUS      = 0x058
USB_EP_STALL_ARM     = 0x068
USB_USB_MUXING       = 0x074
USB_USB_PWR          = 0x078
USB_INTR             = 0x08C
USB_INTE             = 0x090
USB_INTF             = 0x094
USB_INTS             = 0x098

# ---- Bit definitions --------------------------------------------------------
USB_MAIN_CTRL_CTRL_EN     = 1 << 0
USB_MAIN_CTRL_HOST_NDEV   = 1 << 1

USB_MUXING_TO_PHY         = 1 << 0
USB_MUXING_SOFTCON        = 1 << 3

USB_PWR_VBUS_DETECT       = 1 << 2
USB_PWR_VBUS_DETECT_OVR   = 1 << 3

USB_BUFCTRL_AVAILABLE_0   = 1 << 10
USB_BUFCTRL_STALL         = 1 << 11
USB_BUFCTRL_PID_DATA1     = 1 << 13
USB_BUFCTRL_LAST_0        = 1 << 15
USB_BUFCTRL_FULL_0        = 1 << 26

USB_INT_BUFF_STATUS       = 1 << 4
USB_INT_BUS_RESET         = 1 << 12
USB_INT_SETUP_REQ         = 1 << 16

# RESETS bit
RESETS_USBCTRL = 1 << 28

# NVIC IRQ
USBCTRL_IRQ = 14


def map_usb_region(sim) -> None:
    """Map both DPRAM (0x50100000) and controller regs (0x50110000)."""
    from unicorn import (
        UC_PROT_READ, UC_PROT_WRITE,
        UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE,
    )
    # 64 KiB block covers both 0x50100000 (DPRAM) and 0x50110000 (regs)
    base = 0x50100000
    size = 0x20000     # 128 KiB - covers both bars + slack
    try:
        sim.uc.mem_map(base, size, UC_PROT_READ | UC_PROT_WRITE)
    except Exception:
        # Already mapped - fine.
        pass
    sim.uc.hook_add(UC_HOOK_MEM_WRITE, sim._on_write,
                    begin=base, end=base + size - 1)
    sim.uc.hook_add(UC_HOOK_MEM_READ, sim._on_read,
                    begin=base, end=base + size - 1)


def mock_usb_resets_done(sim) -> None:
    """Pre-clear the USB reset bit so usb_device_init's spin exits in 0 cycles.

    Assumes sim.mock_resets_done() has already been installed.
    """
    RESETS_BASE = 0x40020000
    cur = sim.peek32(RESETS_BASE)
    cur &= ~RESETS_USBCTRL
    sim.poke32(RESETS_BASE, cur)
    sim.poke32(RESETS_BASE + 0x08, (~cur) & 0xFFFFFFFF)


def mock_usb_setup(sim,
                   bmRequestType: int,
                   bRequest: int,
                   wValue: int,
                   wIndex: int,
                   wLength: int) -> None:
    """Populate the 8-byte SETUP packet at DPRAM[0..7].

    The host hardware writes this region; from the firmware's POV it's read-
    only.  Tests use this to pretend a SETUP transaction landed.
    """
    pkt = struct.pack("<BBHHH", bmRequestType, bRequest, wValue, wIndex, wLength)
    sim.uc.mem_write(USBCTRL_DPRAM_BASE + DPRAM_SETUP_PACKET, pkt)


def mock_usb_buff_status(sim, mask: int) -> None:
    """Pre-load USB_BUFF_STATUS with `mask` so the ISR will see it.

    BUFF_STATUS is a normal MMIO register from the firmware's POV.
    """
    sim.poke32(USBCTRL_REGS_BASE + USB_BUFF_STATUS, mask)


def mock_usb_ints(sim, mask: int) -> None:
    """Pre-load USB_INTS so the ISR sees `mask` as the active masked irqs."""
    sim.poke32(USBCTRL_REGS_BASE + USB_INTS, mask)


def read_dpram_buf(sim, offset: int, length: int) -> bytes:
    """Read `length` bytes from DPRAM at `offset`."""
    return bytes(sim.uc.mem_read(USBCTRL_DPRAM_BASE + offset, length))


def read_buf_ctrl(sim, ep: int, dir_in: bool) -> int:
    """Read the EP buf_ctrl word.  IN side @ +0, OUT side @ +4."""
    addr = USBCTRL_DPRAM_BASE + DPRAM_EP_BUF_CTRL + 8 * ep
    if not dir_in:
        addr += 4
    return sim.peek32(addr)


def read_ep_ctrl(sim, ep: int, dir_in: bool) -> int:
    """Read the ep_ctrl word for EP n (n >= 1).  IN side @ base, OUT @ +4.

    EP0 has no ep_ctrl (it's implicit); behaviour is undefined for ep == 0.
    """
    addr = USBCTRL_DPRAM_BASE + DPRAM_EP_CTRL_BASE + 8 * (ep - 1)
    if not dir_in:
        addr += 4
    return sim.peek32(addr)
