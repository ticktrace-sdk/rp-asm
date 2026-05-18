# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1: unit tests for the M3 GPIO driver (src/gpio.S).

Strategy:
  * Build a "test fixture" ELF (build/gpio_test_fixture.elf) that
    references every public gpio_* symbol so --gc-sections doesn't
    drop them.
  * Load that ELF; for each test, call into one gpio_* function via
    the AAPCS helper from mocks_gpio.call_function() and inspect the
    resulting MMIO write trace.
  * For the v0.1 regression, also poke through build/blinky_v01.elf
    and assert the historic 4-store init sequence.

Each test asserts on the *exact* address + value of every store the
function emits, locking the contract between assembly source and the
peripheral.
"""

import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim  # noqa: E402
from mocks_gpio import (  # noqa: E402
    ATOMIC_CLR,
    ATOMIC_SET,
    GPIO_FUNC_PIO0,
    GPIO_FUNC_SIO,
    GPIO_FUNC_NULL,
    GPIO_IRQ_EDGE_HIGH,
    GPIO_IRQ_EDGE_LOW,
    IO_BANK0_BASE,
    IO_BANK0_INTR0,
    IO_BANK0_PROC0_INTE0,
    IO_QSPI_BASE,
    PADS_BANK0_BASE,
    PADS_DRIVE_LSB,
    PADS_DRIVE_MASK,
    PADS_IE,
    PADS_ISO_OD,
    PADS_PDE,
    PADS_PUE,
    PADS_SCHMITT,
    PADS_SLEWFAST,
    SIO_BASE,
    SIO_GPIO_HI_OUT_SET,
    SIO_GPIO_HI_OUT_CLR,
    SIO_GPIO_HI_OUT_XOR,
    SIO_GPIO_HI_OE_SET,
    SIO_GPIO_OE_SET,
    SIO_GPIO_OE_CLR,
    SIO_GPIO_OUT_CLR,
    SIO_GPIO_OUT_SET,
    SIO_GPIO_OUT_XOR,
    call_function,
    intr_for,
    io_bank0_ctrl,
    irq_nibble_shift,
    mock_gpio_in,
    pads_bank0_pad_clr,
    pads_bank0_pad_set,
    proc0_inte_clr_for,
    proc0_inte_set_for,
    writes_during,
)

FIXTURE_ELF = os.path.join(REPO, "build", "gpio_test_fixture.elf")
DEMO_ELF = os.path.join(REPO, "build", "gpio_demo.elf")
BLINKY_V01_ELF = os.path.join(REPO, "build", "blinky_v01.elf")


def _need(elf_relpath):
    elf_abs = os.path.join(REPO, elf_relpath)
    if not os.path.exists(elf_abs):
        subprocess.check_call(
            ["make", "-C", REPO, elf_relpath.replace(".elf", ".uf2")],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(elf_abs):
        pytest.skip(f"{elf_abs} missing and `make` did not produce it")


@pytest.fixture
def fixture_sim():
    _need("build/gpio_test_fixture.elf")
    sim = RP2350Sim()
    sim.load_elf(FIXTURE_ELF)
    return sim


def _addrs_values(events):
    return [(e.addr, e.value) for e in events]


# -----------------------------------------------------------------------------
# gpio_set_function
# -----------------------------------------------------------------------------


def test_set_function_pio0_pin7(fixture_sim):
    """gpio_set_function(7, GPIO_FUNC_PIO0) -> single store of 6 to
    IO_BANK0 + 4 + 7*8."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_function"), [7, GPIO_FUNC_PIO0])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(io_bank0_ctrl(7), GPIO_FUNC_PIO0)], (
        f"expected single CTRL write; got {w}")


def test_set_function_uart_pin0(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_function"), [0, 2])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(io_bank0_ctrl(0), 2)]


# -----------------------------------------------------------------------------
# gpio_put / gpio_toggle
# -----------------------------------------------------------------------------


def test_put_high_pin0(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_put"), [0, 1])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_OUT_SET, 1 << 0)], f"got {w}"


def test_put_low_pin25(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_put"), [25, 0])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_OUT_CLR, 1 << 25)], f"got {w}"


def test_put_high_pin33(fixture_sim):
    """Pin 33 lives in the SIO _HI bank with bit position 1."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_put"), [33, 1])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_HI_OUT_SET, 1 << 1)], f"got {w}"


def test_toggle_pin25(fixture_sim):
    """gpio_toggle(25) -> single XOR store of (1<<25)."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_toggle"), [25])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_OUT_XOR, 1 << 25)], f"got {w}"


def test_toggle_pin40(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_toggle"), [40])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_HI_OUT_XOR, 1 << (40 - 32))], (
        f"got {w}")


# -----------------------------------------------------------------------------
# gpio_set_dir
# -----------------------------------------------------------------------------


def test_set_dir_output_pin25(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_dir"), [25, 1])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_OE_SET, 1 << 25)], f"got {w}"


def test_set_dir_input_pin5(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_dir"), [5, 0])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_OE_CLR, 1 << 5)], f"got {w}"


def test_set_dir_output_pin34(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_dir"), [34, 1])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(SIO_GPIO_HI_OE_SET, 1 << (34 - 32))], (
        f"got {w}")


# -----------------------------------------------------------------------------
# gpio_get
# -----------------------------------------------------------------------------


def test_get_returns_one_when_high(fixture_sim):
    from unicorn.arm_const import UC_ARM_REG_R0
    sim = fixture_sim
    mock_gpio_in(sim, 5, 1)
    call_function(sim, sim.symbol("gpio_get"), [5])
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1


def test_get_returns_zero_when_low(fixture_sim):
    from unicorn.arm_const import UC_ARM_REG_R0
    sim = fixture_sim
    mock_gpio_in(sim, 5, 0)
    call_function(sim, sim.symbol("gpio_get"), [5])
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0


def test_get_returns_one_for_high_pin(fixture_sim):
    from unicorn.arm_const import UC_ARM_REG_R0
    sim = fixture_sim
    mock_gpio_in(sim, 35, 1)
    call_function(sim, sim.symbol("gpio_get"), [35])
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1


# -----------------------------------------------------------------------------
# gpio_init - regression against v0.1's 4-store sequence
# -----------------------------------------------------------------------------


def test_gpio_init_pin25_matches_v01_prefix(fixture_sim):
    """gpio_init(25) emits PAD CLR / CTRL=SIO / OUT_CLR / OE_CLR.

    The v0.1 gpio_led_init differs by the *fourth* write (OE_SET vs
    OE_CLR) since v0.1 enables the LED output immediately.  Three of
    four writes match exactly; the fourth is the dir.
    """
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_init"), [25])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [
        (pads_bank0_pad_clr(25), PADS_ISO_OD),
        (io_bank0_ctrl(25),      GPIO_FUNC_SIO),
        (SIO_GPIO_OUT_CLR,       1 << 25),
        (SIO_GPIO_OE_CLR,        1 << 25),
    ], f"gpio_init trace: {w}"


def test_gpio_led_init_v01_regression(fixture_sim):
    """The back-compat shim must match the v0.1 4-store sequence
    exactly: PAD CLR / CTRL=SIO / OUT_CLR / OE_SET."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_led_init"), [])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [
        (pads_bank0_pad_clr(25), PADS_ISO_OD),
        (io_bank0_ctrl(25),      GPIO_FUNC_SIO),
        (SIO_GPIO_OUT_CLR,       1 << 25),
        (SIO_GPIO_OE_SET,        1 << 25),
    ], f"gpio_led_init trace: {w}"


def test_gpio_init_pin40_uses_hi_sio(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_init"), [40])
    w = writes_during(sim, before)
    bit = 1 << (40 - 32)
    assert _addrs_values(w) == [
        (pads_bank0_pad_clr(40),                       PADS_ISO_OD),
        (io_bank0_ctrl(40),                            GPIO_FUNC_SIO),
        (SIO_BASE + 0x060,                             bit),  # HI_OUT_CLR
        (SIO_BASE + 0x080,                             bit),  # HI_OE_CLR
    ], f"gpio_init(40) trace: {w}"


def test_gpio_deinit_pin7(fixture_sim):
    """deinit: mux NULL then PAD SET ISO|OD."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_deinit"), [7])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [
        (io_bank0_ctrl(7),       GPIO_FUNC_NULL),
        (pads_bank0_pad_set(7),  PADS_ISO_OD),
    ], f"gpio_deinit trace: {w}"


# -----------------------------------------------------------------------------
# Pull-up / pull-down / etc.
# -----------------------------------------------------------------------------


def test_pull_up_pin5(fixture_sim):
    """gpio_pull_up(5): SET PUE then CLR PDE - both via atomic aliases."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_pull_up"), [5])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [
        (pads_bank0_pad_set(5), PADS_PUE),
        (pads_bank0_pad_clr(5), PADS_PDE),
    ], f"gpio_pull_up trace: {w}"


def test_pull_down_pin22(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_pull_down"), [22])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [
        (pads_bank0_pad_set(22), PADS_PDE),
        (pads_bank0_pad_clr(22), PADS_PUE),
    ]


def test_disable_pulls_pin11(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_disable_pulls"), [11])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [
        (pads_bank0_pad_clr(11), PADS_PUE | PADS_PDE),
    ]


def test_set_input_enabled_on(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_input_enabled"), [9, 1])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(pads_bank0_pad_set(9), PADS_IE)]


def test_set_input_enabled_off(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_input_enabled"), [9, 0])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(pads_bank0_pad_clr(9), PADS_IE)]


def test_set_drive_strength_8ma(fixture_sim):
    """drive=2 (8mA) -> CLR DRIVE field then SET (2 << 4)."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_drive_strength"), [3, 2])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [
        (pads_bank0_pad_clr(3), PADS_DRIVE_MASK),
        (pads_bank0_pad_set(3), 2 << PADS_DRIVE_LSB),
    ]


def test_set_slew_fast_on(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_slew_fast"), [4, 1])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(pads_bank0_pad_set(4), PADS_SLEWFAST)]


def test_set_schmitt_off(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_schmitt"), [4, 0])
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(pads_bank0_pad_clr(4), PADS_SCHMITT)]


# -----------------------------------------------------------------------------
# IRQ programming
# -----------------------------------------------------------------------------


def test_set_irq_enabled_edge_high_pin7(fixture_sim):
    """gpio_set_irq_enabled(7, EDGE_HIGH, 1):
       expected: PROC0_INTE_SET[7/8] <- (EDGE_HIGH << ((7%8)*4))
                                     = 8 << 28 = 0x80000000."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_irq_enabled"),
                  [7, GPIO_IRQ_EDGE_HIGH, 1])
    w = writes_during(sim, before)
    expected_addr = proc0_inte_set_for(7)
    expected_val = GPIO_IRQ_EDGE_HIGH << irq_nibble_shift(7)
    assert _addrs_values(w) == [(expected_addr, expected_val)], (
        f"got {w}; expected ({hex(expected_addr)}, {hex(expected_val)})")


def test_set_irq_enabled_clears_via_clr_alias(fixture_sim):
    """enable=0 must use the ATOMIC_CLR alias instead of SET."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_irq_enabled"),
                  [12, GPIO_IRQ_EDGE_LOW, 0])
    w = writes_during(sim, before)
    expected_addr = proc0_inte_clr_for(12)
    expected_val = GPIO_IRQ_EDGE_LOW << irq_nibble_shift(12)
    assert _addrs_values(w) == [(expected_addr, expected_val)]


def test_set_irq_enabled_pin47_uses_high_word(fixture_sim):
    """Pin 47 lives in INTE5 (word index = 47/8 = 5)."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_set_irq_enabled"),
                  [47, GPIO_IRQ_EDGE_HIGH, 1])
    w = writes_during(sim, before)
    expected_addr = (IO_BANK0_BASE + ATOMIC_SET + IO_BANK0_PROC0_INTE0
                     + 5 * 4)
    expected_val = GPIO_IRQ_EDGE_HIGH << ((47 % 8) * 4)
    assert _addrs_values(w) == [(expected_addr, expected_val)]


def test_acknowledge_irq_pin7(fixture_sim):
    """gpio_acknowledge_irq(7, EDGE_LOW) writes 1 to the right INTR
    nibble (W1C semantics on the plain alias)."""
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_acknowledge_irq"),
                  [7, GPIO_IRQ_EDGE_LOW])
    w = writes_during(sim, before)
    expected_addr = intr_for(7)
    expected_val = GPIO_IRQ_EDGE_LOW << irq_nibble_shift(7)
    assert _addrs_values(w) == [(expected_addr, expected_val)]


# -----------------------------------------------------------------------------
# IO_QSPI mirror API
# -----------------------------------------------------------------------------


def test_qspi_set_function_sclk(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_qspi_set_function"), [0, 1])  # SPI
    w = writes_during(sim, before)
    assert _addrs_values(w) == [(IO_QSPI_BASE + 4 + 0 * 8, 1)]


def test_qspi_set_irq_enabled_pin2(fixture_sim):
    sim = fixture_sim
    before = len(sim.writes)
    call_function(sim, sim.symbol("gpio_qspi_set_irq_enabled"),
                  [2, GPIO_IRQ_EDGE_HIGH, 1])
    w = writes_during(sim, before)
    expected_addr = IO_QSPI_BASE + ATOMIC_SET + 0x38
    expected_val = GPIO_IRQ_EDGE_HIGH << (2 * 4)
    assert _addrs_values(w) == [(expected_addr, expected_val)]


# -----------------------------------------------------------------------------
# End-to-end: gpio_demo example produces the expected step pattern
# -----------------------------------------------------------------------------


def _full_clock_mocks(sim):
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()


def test_gpio_demo_drives_all_three_pins():
    """Run gpio_demo for ~200k instructions and confirm we see SIO writes
    targeting GP22, GP23, AND GP24 - i.e. the step loop is actually
    iterating across the three pins."""
    _need("build/gpio_demo.elf")
    sim = RP2350Sim()
    sim.load_elf(DEMO_ELF)
    _full_clock_mocks(sim)

    # The example inits the pins, then begins the loop.  Execute long enough
    # to step through the first few entries of the pattern table.
    try:
        sim.run_steps(200_000)
    except Exception:  # pragma: no cover - either way, inspect writes
        pass

    # All SIO OUT_SET / OUT_CLR writes
    sio_out = [
        w for w in sim.writes
        if w.addr in (SIO_GPIO_OUT_SET, SIO_GPIO_OUT_CLR)
    ]
    seen_pins = set()
    for w in sio_out:
        for pin in (22, 23, 24):
            if w.value & (1 << pin):
                seen_pins.add(pin)

    assert {22, 23, 24}.issubset(seen_pins), (
        f"expected gpio_demo to drive pins 22/23/24; saw {seen_pins} "
        f"after {len(sio_out)} SIO OUT writes")


def test_gpio_demo_init_sequence_for_pin22():
    """The first three peripheral writes for GP22 should be PAD CLR,
    CTRL=SIO, OUT_CLR(22) (gpio_init pattern)."""
    _need("build/gpio_demo.elf")
    sim = RP2350Sim()
    sim.load_elf(DEMO_ELF)
    _full_clock_mocks(sim)

    try:
        sim.run_steps(200_000)
    except Exception:
        pass

    # Find the first PAD CLR for pin22
    pad22 = pads_bank0_pad_clr(22)
    pad22_writes = [i for i, w in enumerate(sim.writes) if w.addr == pad22]
    assert pad22_writes, "no PAD CLR for GP22 - gpio_init never called?"

    # The init for pin22 should be followed by CTRL=SIO and OUT_CLR(22)
    idx = pad22_writes[0]
    init_window = sim.writes[idx:idx + 4]
    assert init_window[0].addr == pad22 and init_window[0].value == PADS_ISO_OD
    assert init_window[1].addr == io_bank0_ctrl(22)
    assert init_window[1].value == GPIO_FUNC_SIO
    assert init_window[2].addr == SIO_GPIO_OUT_CLR
    assert init_window[2].value == (1 << 22)
    assert init_window[3].addr == SIO_GPIO_OE_CLR
    assert init_window[3].value == (1 << 22)
