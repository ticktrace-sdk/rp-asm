"""End-to-end T1 test against the v0.1 blinky example.

After M2 (clock-tree bring-up) the production firmware (build/blinky.elf)
runs the M2 boot path, so we can no longer use it for v0.1 trace assertion.
The v0.1 demo is preserved as `examples/blinky_v01.S` and built to
`build/blinky_v01.elf` - that's what this test loads.

Loads build/blinky_v01.elf, mocks the bare minimum of peripherals so the
firmware can make forward progress, and asserts the *exact* sequence of
MMIO writes the v0.1 startup + gpio_led_init + uart0_init + main loop
must perform.

Catches:
  - regression in startup.S reset-clear bitmask
  - wrong PADS_BANK0 ISO|OD value
  - wrong GPIO function code
  - wrong SIO bit position for LED
  - missing UART init writes
  - dropped LED toggle XOR after one full loop iteration

What this does NOT catch (those are T2/T3):
  - timing / clock setup
  - peripheral state-machine semantics (PL011 baud, UART byte stream, etc.)
"""

import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim  # noqa: E402

BLINKY_ELF = os.path.join(REPO, "build", "blinky_v01.elf")

# Constants mirroring include/rp2350.inc - keep in sync with assembly source
RESETS_BASE = 0x40020000
RESETS_RESET_CLR = RESETS_BASE + 0x3000          # ATOMIC_CLR alias on RESET
PADS_BANK0_BASE = 0x40038000
PADS_BANK0_GPIO25_CLR = PADS_BANK0_BASE + 0x3000 + 4 + 25 * 4
PADS_BANK0_GPIO0_CLR  = PADS_BANK0_BASE + 0x3000 + 4 + 0 * 4
PADS_BANK0_GPIO1_CLR  = PADS_BANK0_BASE + 0x3000 + 4 + 1 * 4
IO_BANK0_BASE = 0x40028000
IO_BANK0_GPIO25_CTRL = IO_BANK0_BASE + 4 + 25 * 8
IO_BANK0_GPIO0_CTRL  = IO_BANK0_BASE + 4 + 0 * 8
IO_BANK0_GPIO1_CTRL  = IO_BANK0_BASE + 4 + 1 * 8
SIO_BASE = 0xD0000000
SIO_GPIO_OUT_CLR = SIO_BASE + 0x020
SIO_GPIO_OUT_XOR = SIO_BASE + 0x028
SIO_GPIO_OE_SET  = SIO_BASE + 0x038
UART0_BASE = 0x40070000

SCB_VTOR = 0xE000ED08

PERIPHERAL_RESET_MASK = (1 << 6) | (1 << 9) | (1 << 26)
LED_BIT = 1 << 25
PADS_ISO_OD = (1 << 8) | (1 << 7)            # 0x180


def _peripheral_writes(events):
    """Filter out the SCB_VTOR write done by startup.S - it targets the
    PPB at 0xE000ED08, not a peripheral on the APB."""
    return [w for w in events if w.addr != SCB_VTOR]


def _need_elf():
    if not os.path.exists(BLINKY_ELF):
        # build it from the repo Makefile - keeps the test self-contained
        subprocess.check_call(
            ["make", "-C", REPO, "build/blinky_v01.uf2"],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(BLINKY_ELF):
        pytest.skip(f"{BLINKY_ELF} missing and `make` did not produce it")


@pytest.fixture(scope="module")
def sim():
    _need_elf()
    s = RP2350Sim()
    s.load_elf(BLINKY_ELF)
    s.mock_resets_done()
    s.mock_uart0_tx()
    return s


def test_reset_clears_correct_peripherals(sim: RP2350Sim):
    """startup.S: first peripheral write must be RESETS_RESET CLR with our mask.
    (The actual *first* MMIO write is to SCB_VTOR; we ignore that here.)"""
    # Run just past the RESETS spin loop and into main.  `main` is at a known
    # symbol so we use that as the breakpoint.
    sim.run_until_pc(sim.symbol("main"))

    assert sim.writes, "no MMIO writes observed - did the harness even run?"

    # VTOR comes first
    vtor = sim.writes[0]
    assert vtor.addr == SCB_VTOR, (
        f"first write should be VTOR setup, got {vtor.addr:#x}")

    # First peripheral access is the reset clear
    periph = _peripheral_writes(sim.writes)
    assert periph, "no peripheral writes after VTOR"
    first = periph[0]
    assert first.addr == RESETS_RESET_CLR, (
        f"first peripheral write should target RESETS_RESET CLR "
        f"({RESETS_RESET_CLR:#x}), got {first.addr:#x}")
    assert first.value == PERIPHERAL_RESET_MASK, (
        f"reset mask should be {PERIPHERAL_RESET_MASK:#x}, "
        f"got {first.value:#x}")


def test_blinky_full_init_sequence_then_first_toggle(sim: RP2350Sim):
    """
    After running until the first SIO_GPIO_OUT_XOR store, we expect the
    following MMIO write trace (ignoring any UART DR writes interleaved by
    the banner print, which we identify by address):

        1. RESETS_RESET CLR  = 0x04000240
        2. PADS_BANK0[25] CLR = 0x180
        3. IO_BANK0[25] CTRL  = 5
        4. SIO_GPIO_OUT_CLR   = 1<<25     (drive low first)
        5. SIO_GPIO_OE_SET    = 1<<25
        6. PADS_BANK0[0] CLR  = 0x180     (UART TX pad)
        7. PADS_BANK0[1] CLR  = 0x180     (UART RX pad)
        8. IO_BANK0[0] CTRL   = 2         (UART func)
        9. IO_BANK0[1] CTRL   = 2
       10. UART0 IBRD/FBRD/LCR_H/CR
       11+ banner bytes through UART0 DR (we don't enforce order)
       last. SIO_GPIO_OUT_XOR = 1<<25
    """
    sim.run_until_write(SIO_GPIO_OUT_XOR)

    # Strip out UART DR transactions (everything inside [UART0_BASE,
    # UART0_BASE+0x10) is the data register) and the VTOR setup.
    non_uart_dr = [
        w for w in _peripheral_writes(sim.writes)
        if not (UART0_BASE <= w.addr < UART0_BASE + 0x10)
    ]

    expected_prefix = [
        (RESETS_RESET_CLR,      PERIPHERAL_RESET_MASK),  # 1
        (PADS_BANK0_GPIO25_CLR, 0x180),                  # 2
        (IO_BANK0_GPIO25_CTRL,  5),                      # 3
        (SIO_GPIO_OUT_CLR,      LED_BIT),                # drive low
        (SIO_GPIO_OE_SET,       LED_BIT),                # 4 (OE)
        (PADS_BANK0_GPIO0_CLR,  0x180),                  # uart pads
        (PADS_BANK0_GPIO1_CLR,  0x180),
        (IO_BANK0_GPIO0_CTRL,   2),
        (IO_BANK0_GPIO1_CTRL,   2),
        (UART0_BASE + 0x24,     6),                      # IBRD
        (UART0_BASE + 0x28,     33),                     # FBRD
        (UART0_BASE + 0x2C,     0x70),                   # LCR_H
        (UART0_BASE + 0x30,     0x301),                  # CR
    ]
    actual_prefix = [(w.addr, w.value) for w in non_uart_dr[: len(expected_prefix)]]

    assert actual_prefix == expected_prefix, (
        "init write trace diverges from spec\n"
        f"expected: {[(hex(a), hex(v)) for a, v in expected_prefix]}\n"
        f"got:      {[(hex(a), hex(v)) for a, v in actual_prefix]}\n"
        f"all writes (first 20): {sim.writes[:20]}")

    # And the very last write (the trigger for run_until_write) was the toggle
    last = sim.writes[-1]
    assert last.addr == SIO_GPIO_OUT_XOR
    assert last.value == LED_BIT


def test_uart_banner_prefix():
    """A separate sim instance to keep the test independent of the order one."""
    _need_elf()
    sim = RP2350Sim()
    sim.load_elf(BLINKY_ELF)
    sim.mock_resets_done()
    tx = sim.mock_uart0_tx()
    # Run until we have at least the length of the banner queued up
    sim.run_until_write(SIO_GPIO_OUT_XOR)
    text = bytes(tx).decode("ascii", errors="replace")
    assert text.startswith("rp-asm v0.1"), (
        f"UART output should start with banner, got: {text!r}")
