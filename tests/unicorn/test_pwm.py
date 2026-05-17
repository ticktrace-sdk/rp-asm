# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1: PWM driver trace assertions for src/pwm.S (M3-D).

We exercise each public driver function by:
  1. Loading the `pwm_api.S` fixture ELF.  It pulls in src/pwm.S and pins
     every public symbol via a keepalive table so --gc-sections doesn't
     drop unused functions.
  2. Setting r0..r2 by hand to the desired call arguments.
  3. Pointing PC at the function entry and LR at a halt sentinel.
  4. Running until LR is hit; asserting on sim.writes.

We also verify pwm_set_freq_hz computes the right DIV/TOP for a known
src/freq pair, and that the fade demo ELF actually flips the slice EN bit.
"""

import os
import struct
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim, SRAM_BASE  # noqa: E402
from mocks_pwm import (  # noqa: E402
    PWM_BASE, PWM_CH_CSR, PWM_CH_DIV, PWM_CH_CTR, PWM_CH_CC, PWM_CH_TOP,
    PWM_EN, PWM_INTR, PWM_INTE,
    ATOMIC_SET, ATOMIC_CLR,
    pwm_slice_base, pwm_writes_to,
    gpio_to_slice, gpio_to_chan,
)
from unicorn.arm_const import (  # noqa: E402
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_LR, UC_ARM_REG_PC,
)


# ----------------------------------------------------------------- fixtures


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    """Build tests/unicorn/fixtures/pwm_api.S into an ELF with full symbols."""
    out = tmp_path_factory.mktemp("pwm_fixture")
    src = os.path.join(HERE, "fixtures", "pwm_api.S")
    obj = os.path.join(out, "pwm_api.o")
    elf = os.path.join(out, "pwm_api.elf")
    ld = os.path.join(out, "pwm_api.ld")
    with open(ld, "w") as f:
        # Same shape as the production sram.ld but without IMAGE_DEF padding.
        f.write(f"""ENTRY(_start)
MEMORY {{ SRAM(rwx) : ORIGIN = {hex(SRAM_BASE)}, LENGTH = 64K }}
SECTIONS {{
  .text {hex(SRAM_BASE)} : {{
    KEEP(*(.vectors))
    *(.text._start)
    *(.text*)
    *(.rodata*)
  }} > SRAM
  _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;
}}
""")
    asflags = ["-mcpu=cortex-m33", "-mthumb", "-mimplicit-it=always",
               "-I", os.path.join(REPO, "include")]
    # cwd = REPO so `.include "src/pwm.S"` inside the fixture resolves.
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", obj, src],
        cwd=REPO,
    )
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld, "-nostdlib", "-o", elf, obj])
    return elf


def _load_fixture(elf):
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    return sim


def _call(sim, func_name, *args, max_steps=100_000):
    """Set r0..r{N-1} = args, point PC at func, LR at park sentinel.

    Run until execution reaches the park sentinel (function returned).
    """
    park = sim.symbol("_park")
    func = sim.symbol(func_name)
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2]
    for i, v in enumerate(args):
        sim.uc.reg_write(regs[i], v & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)   # Thumb bit
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=max_steps)


# -----------------------------------------------------------------------------
# Direct register-level checks
# -----------------------------------------------------------------------------


def test_set_clkdiv_int(fixture_elf):
    """pwm_set_clkdiv_int(3, 0x42) writes (0x42<<4) to slice 3 DIV."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_clkdiv_int", 3, 0x42)
    addr = pwm_slice_base(3) + PWM_CH_DIV
    ws = pwm_writes_to(sim, addr)
    assert ws, f"no write to {addr:#x}; trace: {sim.writes}"
    assert ws[-1].value == (0x42 << 4)


def test_set_clkdiv_with_frac(fixture_elf):
    """pwm_set_clkdiv(5, 0x10, 0x7) writes (0x10<<4) | 0x7."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_clkdiv", 5, 0x10, 0x7)
    addr = pwm_slice_base(5) + PWM_CH_DIV
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (0x10 << 4) | 0x7


def test_set_wrap(fixture_elf):
    """pwm_set_wrap(7, 0x1234) writes 0x1234 to slice 7 TOP."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_wrap", 7, 0x1234)
    addr = pwm_slice_base(7) + PWM_CH_TOP
    ws = pwm_writes_to(sim, addr)
    assert ws, f"no write to TOP@slice7; trace: {sim.writes}"
    assert ws[-1].value == 0x1234


def test_set_both_levels(fixture_elf):
    """pwm_set_both_levels(0, 0x80, 0x40) writes (0x40<<16) | 0x80 to CC."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_both_levels", 0, 0x80, 0x40)
    addr = pwm_slice_base(0) + PWM_CH_CC
    ws = pwm_writes_to(sim, addr, size=4)
    assert ws and ws[-1].value == (0x40 << 16) | 0x80


def test_set_chan_level_uses_strh(fixture_elf):
    """pwm_set_chan_level(5, 1, 0xCAFE) does a 16-bit STRH at CC + 2."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_chan_level", 5, 1, 0xCAFE)
    addr = pwm_slice_base(5) + PWM_CH_CC + 2
    ws = pwm_writes_to(sim, addr)
    assert ws, f"no STRH to {addr:#x}; trace: {sim.writes}"
    w = ws[-1]
    assert w.size == 2, f"expected STRH (size=2), got size={w.size}"
    assert w.value & 0xFFFF == 0xCAFE


def test_set_chan_level_a_at_cc_low(fixture_elf):
    """pwm_set_chan_level(2, 0, 0xBEEF) does a 16-bit STRH at CC + 0."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_chan_level", 2, 0, 0xBEEF)
    addr = pwm_slice_base(2) + PWM_CH_CC
    ws = pwm_writes_to(sim, addr, size=2)
    assert ws and ws[-1].value & 0xFFFF == 0xBEEF


def test_set_enabled_uses_atomic_set_alias(fixture_elf):
    """pwm_set_enabled(2, 1) writes (1<<2) to PWM_BASE + ATOMIC_SET + EN."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_enabled", 2, 1)
    addr = PWM_BASE + ATOMIC_SET + PWM_EN
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 2)


def test_set_enabled_off_uses_atomic_clr(fixture_elf):
    """pwm_set_enabled(2, 0) writes (1<<2) to ATOMIC_CLR + EN."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_enabled", 2, 0)
    addr = PWM_BASE + ATOMIC_CLR + PWM_EN
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 2)


def test_irq_enable_uses_atomic_set_alias(fixture_elf):
    """pwm_irq_enable(7, 1) writes (1<<7) to PWM_BASE + ATOMIC_SET + INTE."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_irq_enable", 7, 1)
    addr = PWM_BASE + ATOMIC_SET + PWM_INTE
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 7)


def test_acknowledge_irq(fixture_elf):
    """pwm_acknowledge_irq(11) writes (1<<11) to PWM_BASE + INTR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_acknowledge_irq", 11)
    addr = PWM_BASE + PWM_INTR
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 11)


def test_advance_count_uses_atomic_set_csr(fixture_elf):
    """pwm_advance_count(0) writes PH_ADV (1<<7) to ATOMIC_SET CSR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_advance_count", 0)
    addr = PWM_BASE + ATOMIC_SET + 0 * 0x14 + PWM_CH_CSR
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 7)


def test_retard_count_uses_atomic_set_csr(fixture_elf):
    """pwm_retard_count(0) writes PH_RET (1<<6) to ATOMIC_SET CSR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_retard_count", 0)
    addr = PWM_BASE + ATOMIC_SET + 0 * 0x14 + PWM_CH_CSR
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 6)


def test_phase_correct_on(fixture_elf):
    """pwm_set_phase_correct(4, 1) sets PH_CORRECT via ATOMIC_SET CSR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_phase_correct", 4, 1)
    addr = PWM_BASE + ATOMIC_SET + 4 * 0x14 + PWM_CH_CSR
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 1)


def test_phase_correct_off(fixture_elf):
    """pwm_set_phase_correct(4, 0) clears PH_CORRECT via ATOMIC_CLR CSR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_phase_correct", 4, 0)
    addr = PWM_BASE + ATOMIC_CLR + 4 * 0x14 + PWM_CH_CSR
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == (1 << 1)


def test_output_polarity_a_only(fixture_elf):
    """pwm_set_output_polarity(3, 1, 0): SET A_INV, CLR B_INV."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_output_polarity", 3, 1, 0)
    set_addr = PWM_BASE + ATOMIC_SET + 3 * 0x14 + PWM_CH_CSR
    clr_addr = PWM_BASE + ATOMIC_CLR + 3 * 0x14 + PWM_CH_CSR
    sets = pwm_writes_to(sim, set_addr)
    clrs = pwm_writes_to(sim, clr_addr)
    assert sets and sets[-1].value == (1 << 2)              # A_INV
    assert clrs and clrs[-1].value == (1 << 3)              # B_INV cleared


def test_output_polarity_both(fixture_elf):
    """pwm_set_output_polarity(3, 1, 1) sets both A_INV and B_INV."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_output_polarity", 3, 1, 1)
    set_addr = PWM_BASE + ATOMIC_SET + 3 * 0x14 + PWM_CH_CSR
    sets = pwm_writes_to(sim, set_addr)
    assert sets and sets[-1].value == (1 << 2) | (1 << 3)


def test_resets_enable_clears_pwm_bit(fixture_elf):
    """pwm_resets_enable writes (1<<16) to RESETS_RESET CLR alias."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_resets_enable", max_steps=100_000)
    RESETS_BASE = 0x40020000
    RESETS_RESET_CLR = RESETS_BASE + 0x3000
    ws = pwm_writes_to(sim, RESETS_RESET_CLR)
    assert ws and ws[-1].value == (1 << 16)


def test_set_counter_writes_ctr(fixture_elf):
    """pwm_set_counter(6, 0x4321) writes 0x4321 to slice 6 CTR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_counter", 6, 0x4321)
    addr = pwm_slice_base(6) + PWM_CH_CTR
    ws = pwm_writes_to(sim, addr)
    assert ws and ws[-1].value == 0x4321


def test_set_gpio_function_routes_pad_to_pwm(fixture_elf):
    """pwm_set_gpio_function(15) clears PADS ISO+OD then sets FUNCSEL=4."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_gpio_function", 15)

    PADS_BANK0_BASE = 0x40038000
    IO_BANK0_BASE = 0x40028000

    # PADS_BANK0[15] CLR ISO|OD = 0x180
    pad_clr_addr = PADS_BANK0_BASE + 0x3000 + 4 + 15 * 4
    pad_writes = pwm_writes_to(sim, pad_clr_addr)
    assert pad_writes and pad_writes[-1].value == 0x180, (
        f"PADS CLR write: {pad_writes}")

    # IO_BANK0[15].CTRL = 4
    ctrl_addr = IO_BANK0_BASE + 4 + 15 * 8
    ctrl_writes = pwm_writes_to(sim, ctrl_addr)
    assert ctrl_writes and ctrl_writes[-1].value == 4


# -----------------------------------------------------------------------------
# pwm_set_freq_hz math
# -----------------------------------------------------------------------------


def test_set_freq_hz_1khz_at_150mhz(fixture_elf):
    """pwm_set_freq_hz(0, 1000, 150_000_000) sets DIV.int = 3, TOP = 49999.

    Math: ticks = 150e6 / 1000 = 150_000.  150_000 > 65536 so we need
    DIV.int >= ceil(150000/65536) = 3.  Then TOP+1 = 150_000 / 3 = 50_000.
    """
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_freq_hz", 0, 1000, 150_000_000, max_steps=100_000)

    top_addr = pwm_slice_base(0) + PWM_CH_TOP
    div_addr = pwm_slice_base(0) + PWM_CH_DIV
    tops = pwm_writes_to(sim, top_addr)
    divs = pwm_writes_to(sim, div_addr)
    assert tops, f"no TOP write; trace: {sim.writes}"
    assert divs, f"no DIV write; trace: {sim.writes}"
    assert tops[-1].value == 49_999, f"TOP={tops[-1].value}, want 49999"
    # DIV.int = 3 -> raw value = 3 << 4 = 48
    assert divs[-1].value == (3 << 4), f"DIV={divs[-1].value:#x}, want 0x30"


def test_set_freq_hz_50hz_at_150mhz_servo_case(fixture_elf):
    """pwm_set_freq_hz(0, 50, 150_000_000) - the servo case.

    ticks = 150e6 / 50 = 3_000_000.  ceil(3_000_000 / 65536) = 46.
    TOP+1 = 3_000_000 / 46 = 65_217.  Result frequency = 150e6/(46*65217)
    = ~50.04 Hz.
    """
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_freq_hz", 0, 50, 150_000_000, max_steps=100_000)

    top_addr = pwm_slice_base(0) + PWM_CH_TOP
    div_addr = pwm_slice_base(0) + PWM_CH_DIV
    tops = pwm_writes_to(sim, top_addr)
    divs = pwm_writes_to(sim, div_addr)
    assert tops and divs
    # ceil(3_000_000 / 65536) = 46; TOP+1 = 3_000_000 // 46 = 65217
    div_int = divs[-1].value >> 4
    top = tops[-1].value
    assert div_int == 46, f"DIV.int={div_int}, want 46"
    assert top == 65_217 - 1, f"TOP={top}, want 65216"

    # Verify resulting frequency is within 1% of the request
    actual_hz = 150_000_000.0 / (div_int * (top + 1))
    err = abs(actual_hz - 50) / 50
    assert err < 0.01, f"freq {actual_hz:.2f} off by {err*100:.2f}%"


def test_set_freq_hz_high_freq_uses_div1(fixture_elf):
    """pwm_set_freq_hz(0, 10_000, 150_000_000) keeps DIV.int = 1.

    ticks = 15_000 < 65536 so DIV stays at 1.  TOP = 14_999.
    """
    sim = _load_fixture(fixture_elf)
    _call(sim, "pwm_set_freq_hz", 0, 10_000, 150_000_000, max_steps=100_000)
    div_addr = pwm_slice_base(0) + PWM_CH_DIV
    top_addr = pwm_slice_base(0) + PWM_CH_TOP
    divs = pwm_writes_to(sim, div_addr)
    tops = pwm_writes_to(sim, top_addr)
    assert divs[-1].value == (1 << 4), f"DIV={divs[-1].value}, want 0x10"
    assert tops[-1].value == 14_999, f"TOP={tops[-1].value}, want 14999"


# -----------------------------------------------------------------------------
# Slice / channel mapping (verified against RP2350 datasheet sec 12.5)
# -----------------------------------------------------------------------------


def test_gpio_to_slice_table():
    """Pin -> (slice, channel) per the formula in include/pwm.inc.

    Formula:  slice = ((pin >> 1) & 7) | ((pin >> 4) & 8)
              chan  = pin & 1   (A=0 even pins, B=1 odd pins)

    Only the cases that we actually use in examples (GP0, GP15, GP25) are
    load-bearing; the others document the wrap behaviour for reference.
    Note: slices 8..11 are not reachable via GP0..GP47 with this formula;
    on the RP2350 they're available only via PWM-internal sources.
    """
    cases = [
        # (gpio, expected_slice, expected_chan)
        (0,  0, 0),       # A
        (1,  0, 1),       # B
        (2,  1, 0),
        (15, 7, 1),       # GP15 -> slice 7 ch B   (used in fade/servo demos)
        (16, 0, 0),
        (24, 4, 0),
        (25, 4, 1),       # GP25 -> slice 4 ch B   (on-board LED)
        (47, 7, 1),       # high end of the range
    ]
    for pin, exp_slice, exp_chan in cases:
        assert gpio_to_slice(pin) == exp_slice, (
            f"GP{pin}: slice {gpio_to_slice(pin)}, want {exp_slice}")
        assert gpio_to_chan(pin) == exp_chan


# -----------------------------------------------------------------------------
# End-to-end: build the fade demo and assert the slice gets enabled
# -----------------------------------------------------------------------------


FADE_ELF = os.path.join(REPO, "build", "pwm_fade_demo.elf")


def _need_fade_elf():
    if not os.path.exists(FADE_ELF):
        subprocess.check_call(
            ["make", "-C", REPO, "build/pwm_fade_demo.uf2"],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(FADE_ELF):
        pytest.skip(f"{FADE_ELF} missing and `make` did not produce it")


def test_fade_demo_enables_slice_4():
    """pwm_fade_demo enables slice 4 (GP25 ch B = on-board LED) after configuring DIV/TOP."""
    _need_fade_elf()
    sim = RP2350Sim()
    sim.load_elf(FADE_ELF)
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()
    sim.mock_uart0_tx()

    # Run until the slice EN bit is set.
    en_addr = PWM_BASE + ATOMIC_SET + PWM_EN
    sim.run_until_write(en_addr, max_steps=200_000)

    ws = pwm_writes_to(sim, en_addr)
    assert ws, "slice never enabled"
    # Slice 4 -> bit 4 (= 0x10)
    assert ws[-1].value == (1 << 4), (
        f"unexpected EN write value: {ws[-1].value:#x}, want {1<<4:#x}")


def test_fade_demo_writes_top_and_div_for_slice_4():
    """The fade demo programs slice-4 TOP=100 and DIV.int=6 before enabling."""
    _need_fade_elf()
    sim = RP2350Sim()
    sim.load_elf(FADE_ELF)
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()
    sim.mock_uart0_tx()

    en_addr = PWM_BASE + ATOMIC_SET + PWM_EN
    sim.run_until_write(en_addr, max_steps=200_000)

    div4 = pwm_writes_to(sim, pwm_slice_base(4) + PWM_CH_DIV)
    top4 = pwm_writes_to(sim, pwm_slice_base(4) + PWM_CH_TOP)
    assert div4 and div4[-1].value == (6 << 4), f"DIV={div4}"
    assert top4 and top4[-1].value == 100, f"TOP={top4}"


def test_fade_demo_routes_gp25_to_pwm_function():
    """pwm_set_gpio_function(25) writes FUNCSEL=4 at IO_BANK0[25]."""
    _need_fade_elf()
    sim = RP2350Sim()
    sim.load_elf(FADE_ELF)
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()
    sim.mock_uart0_tx()

    en_addr = PWM_BASE + ATOMIC_SET + PWM_EN
    sim.run_until_write(en_addr, max_steps=200_000)

    ctrl_addr = 0x40028000 + 4 + 25 * 8
    ctrl_writes = pwm_writes_to(sim, ctrl_addr)
    assert ctrl_writes and ctrl_writes[-1].value == 4, (
        f"GP25 CTRL writes: {ctrl_writes}")
