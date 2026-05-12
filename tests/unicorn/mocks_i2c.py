"""I2C (DesignWare DW_apb_i2c) mocks for the RP2350Sim harness (M4-F).

The driver in src/i2c.S has several "spin until X" loops that need a
peripheral model to exit:

  - i2c_init                 spins on RESETS_RESET_DONE bit (i2c0=4 / i2c1=5)
                             - covered by RP2350Sim.mock_resets_done.
  - i2c_write_blocking       spins on IC_STATUS.TFNF (bit 1) before each
                             store, then on MST_ACTIVITY (bit 5) at the end.
  - i2c_read_blocking        same TFNF spin to push commands, then RFNE
                             (bit 3) spin to pop received bytes.

`mock_i2c_status(sim, idx, status)`           -- IC_STATUS reads return value
`mock_i2c_rxfifo(sim, idx, bytes_seq)`        -- pops bytes on each
                                                 IC_DATA_CMD read; advances
                                                 RXFLR shadow accordingly.
`mock_i2c_busy_then_idle(sim, idx, n_polls)`  -- IC_STATUS BUSY / MST_ACTIVITY
                                                 bit clears after n polls.

All three functions assume sim.mock_resets_done() has been installed.
"""

from __future__ import annotations

from typing import List, Sequence


I2C0_BASE = 0x40090000
I2C1_BASE = 0x40098000
I2C_INSTANCE_STRIDE = I2C1_BASE - I2C0_BASE     # = 0x8000

# Per-instance offsets (matches include/i2c.inc verbatim)
IC_CON              = 0x00
IC_TAR              = 0x04
IC_SAR              = 0x08
IC_DATA_CMD         = 0x10
IC_SS_SCL_HCNT      = 0x14
IC_SS_SCL_LCNT      = 0x18
IC_FS_SCL_HCNT      = 0x1C
IC_FS_SCL_LCNT      = 0x20
IC_INTR_STAT        = 0x2C
IC_INTR_MASK        = 0x30
IC_RAW_INTR_STAT    = 0x34
IC_RX_TL            = 0x38
IC_TX_TL            = 0x3C
IC_CLR_INTR         = 0x40
IC_CLR_RX_UNDER     = 0x44
IC_CLR_RX_OVER      = 0x48
IC_CLR_TX_OVER      = 0x4C
IC_CLR_RD_REQ       = 0x50
IC_CLR_TX_ABRT      = 0x54
IC_CLR_RX_DONE      = 0x58
IC_CLR_ACTIVITY     = 0x5C
IC_CLR_STOP_DET     = 0x60
IC_CLR_START_DET    = 0x64
IC_ENABLE           = 0x6C
IC_STATUS           = 0x70
IC_TXFLR            = 0x74
IC_RXFLR            = 0x78
IC_SDA_HOLD         = 0x7C
IC_TX_ABRT_SOURCE   = 0x80
IC_DMA_CR           = 0x88
IC_DMA_TDLR         = 0x8C
IC_DMA_RDLR         = 0x90
IC_ENABLE_STATUS    = 0x9C
IC_FS_SPKLEN        = 0xA0

# IC_STATUS bits
IC_STATUS_ACTIVITY      = 1 << 0
IC_STATUS_TFNF          = 1 << 1
IC_STATUS_TFE           = 1 << 2
IC_STATUS_RFNE          = 1 << 3
IC_STATUS_RFF           = 1 << 4
IC_STATUS_MST_ACTIVITY  = 1 << 5
IC_STATUS_SLV_ACTIVITY  = 1 << 6

# IC_DATA_CMD bits
IC_DATA_CMD_CMD     = 1 << 8
IC_DATA_CMD_STOP    = 1 << 9
IC_DATA_CMD_RESTART = 1 << 10

# IC_INTR_* bits
IC_INTR_RX_UNDER    = 1 << 0
IC_INTR_RX_OVER     = 1 << 1
IC_INTR_RX_FULL     = 1 << 2
IC_INTR_TX_OVER     = 1 << 3
IC_INTR_TX_EMPTY    = 1 << 4
IC_INTR_RD_REQ      = 1 << 5
IC_INTR_TX_ABRT     = 1 << 6
IC_INTR_RX_DONE     = 1 << 7
IC_INTR_ACTIVITY    = 1 << 8
IC_INTR_STOP_DET    = 1 << 9
IC_INTR_START_DET   = 1 << 10

RESETS_I2C0 = 1 << 4
RESETS_I2C1 = 1 << 5


def i2c_base(idx: int) -> int:
    """Return the absolute base for instance `idx` (0 or 1)."""
    return I2C0_BASE + idx * I2C_INSTANCE_STRIDE


def mock_i2c_resets_done(sim) -> None:
    """Pre-clear the I2C reset bits so i2c_init's spin exits immediately.

    Assumes sim.mock_resets_done() has been installed.  We just poke
    RESETS_RESET to clear bits 4 and 5 and mirror that into RESET_DONE.
    """
    RESETS_BASE = 0x40020000
    cur = sim.peek32(RESETS_BASE)
    cur &= ~(RESETS_I2C0 | RESETS_I2C1)
    sim.poke32(RESETS_BASE, cur)
    sim.poke32(RESETS_BASE + 0x08, (~cur) & 0xFFFFFFFF)


def mock_i2c_status(sim, idx: int, status: int) -> None:
    """Make every read of IC_STATUS for instance `idx` return `status`.

    Combine flags as `IC_STATUS_TFNF | IC_STATUS_TFE | ...`.  For the common
    "ready to write a byte" case use `IC_STATUS_TFNF`; for "ready to read"
    use `IC_STATUS_RFNE`.  MST_ACTIVITY off (bit 5 = 0) is needed for the
    end-of-transaction spin in write/read_blocking to exit.
    """
    base = i2c_base(idx)

    def read_cb(addr: int, size: int):
        if (addr - base) == IC_STATUS:
            return status
        return None

    sim.on_read(base, 0x4000, read_cb)


def mock_i2c_rxfifo(sim, idx: int, bytes_seq: Sequence[int]) -> dict:
    """Realistic RX-side mock: each WRITE to IC_DATA_CMD with CMD=1 pulls
    the next byte from `bytes_seq` and stages it as the next IC_DATA_CMD
    read.  This mirrors the silicon: a master read on the bus produces
    one RX byte per command.

    IC_STATUS.RFNE reads as 1 while there is a staged byte not yet read.
    TFNF and !MST_ACTIVITY are always reported so the write-side spin
    loops still exit.

    Returns {'remaining': <bytes still in the source queue>,
             'staged'   : <bytes pending in the simulated RX FIFO>}.
    """
    base = i2c_base(idx)
    state = {"queue": list(bytes_seq), "staged": []}

    def write_cb(addr: int, value: int, size: int) -> None:
        if (addr - base) == IC_DATA_CMD:
            # CMD bit (1<<8) means "issue read" - stage one RX byte.
            if value & (1 << 8) and state["queue"]:
                state["staged"].append(state["queue"].pop(0) & 0xFF)

    def read_cb(addr: int, size: int):
        offset = addr - base
        if offset == IC_STATUS:
            s = IC_STATUS_TFNF | IC_STATUS_TFE
            if state["staged"]:
                s |= IC_STATUS_RFNE
            return s
        if offset == IC_DATA_CMD:
            if state["staged"]:
                return state["staged"].pop(0) & 0xFF
            return 0
        if offset == IC_RXFLR:
            return len(state["staged"])
        if offset == IC_TX_ABRT_SOURCE:
            return 0
        return None

    sim.on_write(base, 0x4000, write_cb)
    sim.on_read(base, 0x4000, read_cb)
    state["remaining"] = state["queue"]
    return state


def mock_i2c_busy_then_idle(sim, idx: int, n_polls: int) -> dict:
    """IC_STATUS reports MST_ACTIVITY=1 for the first `n_polls` reads,
    then MST_ACTIVITY=0 (and TFNF stays high so writes proceed unblocked).

    Returns {'reads': <count of IC_STATUS reads observed>}.
    """
    base = i2c_base(idx)
    state = {"reads": 0}

    def read_cb(addr: int, size: int):
        if (addr - base) == IC_STATUS:
            state["reads"] += 1
            s = IC_STATUS_TFNF | IC_STATUS_TFE
            if state["reads"] <= n_polls:
                s |= IC_STATUS_MST_ACTIVITY
            return s
        if (addr - base) == IC_TX_ABRT_SOURCE:
            return 0
        return None

    sim.on_read(base, 0x4000, read_cb)
    return state


def mock_i2c_ready(sim, idx: int) -> None:
    """The everyman mock: TFNF + TFE + !MST_ACTIVITY at all times, so
    write_blocking flies through without waiting on hardware.  Useful for
    "did the driver issue the right writes?" assertions where the test
    doesn't care about RX traffic.
    """
    mock_i2c_status(sim, idx, IC_STATUS_TFNF | IC_STATUS_TFE)
