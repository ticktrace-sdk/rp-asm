# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""DMA mocks for the RP2350Sim harness (M3-C).

The driver in src/dma.S has a few "spin until X" loops that need a peripheral
model to exit:

  - dma_init             spins on RESETS_RESET_DONE.bit2 (covered by
                         RP2350Sim.mock_resets_done already; this file just
                         pre-clears the dma bit so the spin exits at once).
  - dma_channel_wait_for_finish  spins on CHn_CTRL_TRIG.BUSY (bit 26).
  - dma_channel_abort    spins on DMA_CHAN_ABORT.bitch.

`mock_dma_finishes_after(sim, ch, n_polls)` is the bread-and-butter mock:
read CHn_CTRL_TRIG and return BUSY=1 for the first `n_polls` reads, then
BUSY=0.  Tests use it to confirm the spin exits exactly when the bit clears.

`mock_dma_functional_copy(sim)` is the more ambitious option: it actually
performs the byte-level copy when the firmware writes CTRL_TRIG (or any
trigger alias).  Lets tests assert on the destination buffer contents
*after* dma_channel_wait_for_finish returns.
"""

from __future__ import annotations

import struct
from typing import Dict


DMA_BASE = 0x50000000
DMA_CHANNEL_STRIDE = 0x40

# Per-channel offsets (alias 0)
CH_READ_ADDR = 0x00
CH_WRITE_ADDR = 0x04
CH_TRANS_COUNT = 0x08
CH_CTRL_TRIG = 0x0C

# AL1
CH_AL1_CTRL = 0x10
CH_AL1_READ_ADDR = 0x14
CH_AL1_WRITE_ADDR = 0x18
CH_AL1_TRANS_COUNT_TRIG = 0x1C
# AL2
CH_AL2_CTRL = 0x20
CH_AL2_TRANS_COUNT = 0x24
CH_AL2_READ_ADDR = 0x28
CH_AL2_WRITE_ADDR_TRIG = 0x2C
# AL3
CH_AL3_CTRL = 0x30
CH_AL3_WRITE_ADDR = 0x34
CH_AL3_TRANS_COUNT = 0x38
CH_AL3_READ_ADDR_TRIG = 0x3C

# Global registers
DMA_INTR = 0x400
DMA_INTE0 = 0x404
DMA_INTE1 = 0x414
DMA_INTE2 = 0x424
DMA_INTE3 = 0x434
DMA_MULTI_CHAN_TRIGGER = 0x430
DMA_SNIFF_CTRL = 0x434  # NB: aliased with INTE3 in early datasheet drafts;
                        # M3-C driver treats them as distinct registers and
                        # the harness mocks each address explicitly.
DMA_SNIFF_DATA = 0x438
DMA_CHAN_ABORT = 0x444

# CTRL bits
CTRL_BUSY = 1 << 26
CTRL_DATA_SIZE_LSB = 2
CTRL_DATA_SIZE_MASK = 0x3 << CTRL_DATA_SIZE_LSB

# RESETS bit
RESETS_DMA = 1 << 2


def channel_base(ch: int) -> int:
    return DMA_BASE + ch * DMA_CHANNEL_STRIDE


# The DMA controller lives at 0x50000000, *outside* the APB window the
# harness pre-maps (0x40000000..0x4FFFFFFF).  Tests must call this once
# per simulator before exercising the DMA driver, otherwise the first
# store traps with UC_ERR_WRITE_UNMAPPED.
DMA_REGION_SIZE = 0x10000  # covers per-channel block + global regs + ATOMIC


def map_dma_region(sim) -> None:
    """Map a 64 KiB window at DMA_BASE so MMIO accesses don't bus-fault.

    Idempotent: re-mapping an already-mapped region raises UC_ERR_MAP, so
    we swallow that case (the test fixture pattern re-creates the sim each
    test, but a few helpers may call this defensively from multiple sites).
    Also installs the DMA->harness MMIO hooks the rest of mocks_dma relies on
    if they aren't already attached, by inheriting RP2350Sim's hook layer
    via on_write/on_read in the caller.
    """
    from unicorn import UC_PROT_READ, UC_PROT_WRITE
    try:
        sim.uc.mem_map(DMA_BASE, DMA_REGION_SIZE,
                       UC_PROT_READ | UC_PROT_WRITE)
    except Exception:
        # Already mapped - fine.
        pass
    # The harness's MMIO read/write recording hooks are scoped to APB +
    # SIO + PPB at construction time.  Add a recording hook for our region
    # so test assertions on `sim.writes` still see DMA traffic.
    from unicorn import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
    sim.uc.hook_add(UC_HOOK_MEM_WRITE, sim._on_write,
                    begin=DMA_BASE, end=DMA_BASE + DMA_REGION_SIZE - 1)
    sim.uc.hook_add(UC_HOOK_MEM_READ, sim._on_read,
                    begin=DMA_BASE, end=DMA_BASE + DMA_REGION_SIZE - 1)


def mock_dma_resets_done(sim) -> None:
    """Pre-clear the DMA reset bit so dma_init's spin exits in zero time.

    Assumes sim.mock_resets_done() has already been installed.  We just
    poke RESETS_RESET to clear bit 2 and mirror it into RESET_DONE.
    """
    RESETS_BASE = 0x40020000
    cur = sim.peek32(RESETS_BASE)
    cur &= ~RESETS_DMA
    sim.poke32(RESETS_BASE, cur)
    sim.poke32(RESETS_BASE + 0x08, (~cur) & 0xFFFFFFFF)


def mock_dma_finishes_after(sim, ch: int, n_polls: int) -> Dict[str, int]:
    """Make CHn_CTRL_TRIG.BUSY read 1 for `n_polls` accesses, then 0.

    Returns a dict that the test can introspect:
      {'reads': <total CTRL_TRIG reads observed>}
    """
    base = channel_base(ch)
    state = {"reads": 0}

    def read_cb(addr: int, size: int):
        offset = addr - base
        if offset != CH_CTRL_TRIG:
            return None
        state["reads"] += 1
        # Return a CTRL value with BUSY for the first n_polls reads, then 0.
        if state["reads"] <= n_polls:
            return CTRL_BUSY
        return 0

    sim.on_read(base, DMA_CHANNEL_STRIDE, read_cb)
    return state


def mock_dma_abort_completes(sim) -> None:
    """Auto-clear DMA_CHAN_ABORT after the firmware writes it.

    Real silicon reads back ABORT as 1 until the channel halts.  We model
    "halts in zero time": the next read returns 0.
    """
    state = {"abort": 0}

    def write_cb(addr: int, value: int, size: int) -> None:
        if (addr & 0xFFF) == DMA_CHAN_ABORT:
            # Silicon: setting bits in CHAN_ABORT requests abort; HW clears
            # them when the channel halts.  We clear immediately on the next
            # read by stashing 0 into our shadow.
            state["abort"] = 0

    def read_cb(addr: int, size: int):
        if (addr & 0xFFF) == DMA_CHAN_ABORT:
            return state["abort"]
        return None

    sim.on_write(DMA_BASE, 0x4000, write_cb)
    sim.on_read(DMA_BASE, 0x4000, read_cb)


def mock_dma_functional_copy(sim) -> Dict[int, dict]:
    """Functional model: actually performs the copy on trigger-alias writes.

    Tracks per-channel state (read/write/count/ctrl).  When the firmware
    writes a triggering alias (CTRL_TRIG, AL1_TRANS_COUNT_TRIG, ...) the
    mock copies (count * data_size) bytes from READ_ADDR to WRITE_ADDR
    inside Unicorn's mapped memory.

    The returned dict is keyed by channel index and contains the latest
    snapshot of per-channel registers - useful for test assertions.
    """
    state: Dict[int, dict] = {
        ch: {"read": 0, "write": 0, "count": 0, "ctrl": 0, "busy": False}
        for ch in range(16)
    }

    triggering = {
        CH_CTRL_TRIG,
        CH_AL1_TRANS_COUNT_TRIG,
        CH_AL2_WRITE_ADDR_TRIG,
        CH_AL3_READ_ADDR_TRIG,
    }

    def _data_size_bytes(ctrl: int) -> int:
        ds = (ctrl & CTRL_DATA_SIZE_MASK) >> CTRL_DATA_SIZE_LSB
        return {0: 1, 1: 2, 2: 4}.get(ds, 1)

    def _do_copy(ch: int):
        s = state[ch]
        n_bytes = s["count"] * _data_size_bytes(s["ctrl"])
        if n_bytes <= 0 or s["read"] == 0 or s["write"] == 0:
            s["busy"] = False
            return
        # Read source bytes, write dest bytes.  We don't model address
        # increment vs fixed because for the demos in M3-C INCR_READ /
        # INCR_WRITE are always set; the unit test that doesn't care about
        # the dst contents (e.g. the UART demo) just inspects the issued
        # writes via sim.writes.
        try:
            blob = sim.uc.mem_read(s["read"], n_bytes)
            sim.uc.mem_write(s["write"], bytes(blob))
        except Exception:
            pass
        s["busy"] = False

    def write_cb(addr: int, value: int, size: int) -> None:
        # Filter to per-channel space (DMA_BASE..DMA_BASE+0x400).  Skip the
        # global-register window above 0x400.
        offset = addr - DMA_BASE
        if not (0 <= offset < 0x400):
            return
        ch = offset // DMA_CHANNEL_STRIDE
        sub = offset % DMA_CHANNEL_STRIDE

        s = state[ch]
        # Track every per-register update we care about, regardless of
        # whether it triggers.
        if sub in (CH_READ_ADDR, CH_AL1_READ_ADDR, CH_AL2_READ_ADDR,
                   CH_AL3_READ_ADDR_TRIG):
            s["read"] = value
        elif sub in (CH_WRITE_ADDR, CH_AL1_WRITE_ADDR, CH_AL3_WRITE_ADDR,
                     CH_AL2_WRITE_ADDR_TRIG):
            s["write"] = value
        elif sub in (CH_TRANS_COUNT, CH_AL1_TRANS_COUNT_TRIG,
                     CH_AL2_TRANS_COUNT, CH_AL3_TRANS_COUNT):
            s["count"] = value
        elif sub in (CH_CTRL_TRIG, CH_AL1_CTRL, CH_AL2_CTRL, CH_AL3_CTRL):
            s["ctrl"] = value

        if sub in triggering:
            s["busy"] = True
            _do_copy(ch)

    def read_cb(addr: int, size: int):
        offset = addr - DMA_BASE
        if not (0 <= offset < 0x400):
            return None
        ch = offset // DMA_CHANNEL_STRIDE
        sub = offset % DMA_CHANNEL_STRIDE
        if sub == CH_CTRL_TRIG:
            # Reflect the most recent CTRL with BUSY shadowed in.
            ctrl = state[ch]["ctrl"] & ~CTRL_BUSY
            if state[ch]["busy"]:
                ctrl |= CTRL_BUSY
            return ctrl
        return None

    sim.on_write(DMA_BASE, 0x4000, write_cb)
    sim.on_read(DMA_BASE, 0x4000, read_cb)
    return state
