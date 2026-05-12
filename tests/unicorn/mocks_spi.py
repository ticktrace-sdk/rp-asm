"""SPI (PL022) mocks for the RP2350Sim harness (M4-G).

The driver in src/spi.S has a few "spin until X" / "poll until Y" loops
that need a peripheral model to make forward progress under Unicorn:

  * spi_init / spi_set_baudrate / spi_set_format / spi_set_loopback /
    spi_set_slave - all touch CR1 (read-modify-write to twiddle SSE).  No
    spin loop needed, but reads must return a sensible CR1 value.
  * spi_write_blocking and friends spin on SSPSR.TNF / SSPSR.RNE / SSPSR.BSY.
    Without a model, SSPSR reads as zero -> TNF=0 -> infinite spin.

`mock_spi_status(sim, idx, status)` plants a static status word at SSPSR for
SPI<idx>; tests that just need "TNF=1, RNE=0" use this to short-circuit
polling.

`mock_spi_loopback(sim, idx, depth=8)` is the more functional option: it
captures every store to SSPDR and queues the value into a Python deque.
The next read of SSPDR pops the head.  SSPSR.TNF and SSPSR.RNE are
synthesised from the deque's depth so a write_read_blocking that pushes
N bytes will receive N matching bytes back, enabling end-to-end tests.
"""

from __future__ import annotations

from collections import deque
from typing import Dict


SPI0_BASE = 0x40080000
SPI1_BASE = 0x40088000
SPI_INSTANCE_STRIDE = 0x00008000

# PL022 register offsets
SSPCR0 = 0x00
SSPCR1 = 0x04
SSPDR = 0x08
SSPSR = 0x0C
SSPCPSR = 0x10
SSPIMSC = 0x14
SSPRIS = 0x18
SSPMIS = 0x1C
SSPICR = 0x20
SSPDMACR = 0x24

# SSPSR bits
SSPSR_TFE = 1 << 0
SSPSR_TNF = 1 << 1
SSPSR_RNE = 1 << 2
SSPSR_RFF = 1 << 3
SSPSR_BSY = 1 << 4

# SSPCR1 bits
SSPCR1_LBM = 1 << 0
SSPCR1_SSE = 1 << 1
SSPCR1_MS = 1 << 2
SSPCR1_SOD = 1 << 3

# SSPDMACR bits
SSPDMACR_RXDMAE = 1 << 0
SSPDMACR_TXDMAE = 1 << 1

# RESETS bit positions
RESETS_SPI0 = 1 << 18
RESETS_SPI1 = 1 << 19


def spi_base(idx: int) -> int:
    return SPI0_BASE + idx * SPI_INSTANCE_STRIDE


def mock_spi_resets_done(sim) -> None:
    """Pre-clear SPI0 + SPI1 reset bits so spi_init's spin exits at once.

    Assumes sim.mock_resets_done() has already been installed.
    """
    RESETS_BASE = 0x40020000
    cur = sim.peek32(RESETS_BASE)
    cur &= ~(RESETS_SPI0 | RESETS_SPI1)
    sim.poke32(RESETS_BASE, cur)
    sim.poke32(RESETS_BASE + 0x08, (~cur) & 0xFFFFFFFF)


def mock_spi_status(sim, idx: int, status: int) -> None:
    """SSPSR for SPI<idx> always returns the given value.

    Use this to short-circuit polling loops in the driver - e.g. set
    `SSPSR_TNF | SSPSR_TFE` to make spi_write_blocking treat the FIFO as
    always-empty and run to completion in zero polls.

    A single status word covers every read of SSPSR; the harness installs
    a region read hook over [base, base+0x40).
    """
    base = spi_base(idx)

    def read_cb(addr: int, size: int):
        if (addr - base) & 0xFFF == SSPSR:
            return status
        return None

    sim.on_read(base, 0x40, read_cb)


def mock_spi_loopback(sim, idx: int, depth: int = 8) -> Dict[str, object]:
    """Functional FIFO loopback for SPI<idx>.

    Stores written to SSPDR are appended to a deque (capped at `depth`);
    reads of SSPDR pop the head.  SSPSR.TNF reflects "depth not yet hit"
    and SSPSR.RNE reflects "deque non-empty".  SSPSR.TFE reflects
    "deque empty" and SSPSR.BSY reflects "deque non-empty" (a coarse
    approximation: real silicon's BSY clears a few SCK after the last bit
    leaves the serialiser, but for trace-level T1 tests this is sufficient).

    Returns a dict the test can introspect:
        {"tx": deque(...),       # bytes the driver pushed (in order)
         "rx_log": [..],         # bytes we returned on SSPDR reads (in order)
         "stats": {...}}
    """
    base = spi_base(idx)
    fifo: deque = deque(maxlen=depth)
    state = {"tx": deque(), "rx_log": [], "stats": {"writes": 0, "reads": 0}}

    def status_word() -> int:
        s = 0
        if len(fifo) < depth:
            s |= SSPSR_TNF
        if len(fifo) == 0:
            s |= SSPSR_TFE
        else:
            s |= SSPSR_RNE
        if len(fifo) == depth:
            s |= SSPSR_RFF
        # BSY = deque non-empty (i.e. at least one byte hasn't been clocked
        # out); in our model "clocking out" means the firmware reads SSPDR.
        if len(fifo) > 0:
            s |= SSPSR_BSY
        return s

    def read_cb(addr: int, size: int):
        offset = (addr - base) & 0xFFF
        if offset == SSPSR:
            return status_word()
        if offset == SSPDR:
            state["stats"]["reads"] += 1
            if not fifo:
                return 0
            v = fifo.popleft()
            state["rx_log"].append(v)
            return v
        return None

    def write_cb(addr: int, value: int, size: int) -> None:
        offset = (addr - base) & 0xFFF
        if offset == SSPDR:
            fifo.append(value & 0xFF)
            state["tx"].append(value & 0xFF)
            state["stats"]["writes"] += 1

    sim.on_read(base, 0x40, read_cb)
    sim.on_write(base, 0x40, write_cb)
    return state


def mock_spi_cr1_readback(sim, idx: int) -> Dict[str, int]:
    """Mirror writes to SSPCR1 so subsequent reads return the latest value.

    The driver's RMW pattern (read CR1, mask SSE off, write back, do
    something, write back the original) only works if SSPCR1 reads return
    what was last written.  Unicorn's default APB region is plain RAM, so
    writes do persist - but we expose this hook for completeness and to
    let tests assert on the live value after a sequence.

    Returns a dict {'last': last value seen}.
    """
    base = spi_base(idx)
    state = {"last": 0}

    def write_cb(addr: int, value: int, size: int) -> None:
        if (addr - base) & 0xFFF == SSPCR1:
            state["last"] = value & 0xFFFFFFFF

    sim.on_write(base, 0x40, write_cb)
    return state
