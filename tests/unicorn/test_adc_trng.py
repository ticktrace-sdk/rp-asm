# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 tests for the M5-J ADC and TRNG drivers."""

import os
import struct
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim, SRAM_BASE  # noqa: E402
from unicorn.arm_const import (  # noqa: E402
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
    UC_ARM_REG_LR, UC_ARM_REG_PC,
)

# ----- Addresses ------------------------------------------------------------
ADC_BASE = 0x400A0000
ADC_CS = ADC_BASE + 0x00
ADC_RESULT = ADC_BASE + 0x04
ADC_FCS = ADC_BASE + 0x08
ADC_FIFO = ADC_BASE + 0x0C
ADC_DIV = ADC_BASE + 0x10

TRNG_BASE = 0x400F0000
TRNG_RND_SOURCE_ENABLE = TRNG_BASE + 0x12C
TRNG_VALID = TRNG_BASE + 0x110
TRNG_EHR_DATA0 = TRNG_BASE + 0x114
TRNG_RNG_ICR = TRNG_BASE + 0x108

RESETS_BASE = 0x40020000
RESETS_RESET_CLR = RESETS_BASE + 0x3000

CS_EN = 1 << 0
CS_TS_EN = 1 << 1
CS_READY = 1 << 8
CS_START_ONCE = 1 << 2
CS_AINSEL_SHIFT = 12


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("adc_trng_fixture")
    src = os.path.join(HERE, "fixtures", "adc_trng_api.S")
    obj = os.path.join(out, "adc_trng_api.o")
    elf = os.path.join(out, "adc_trng_api.elf")
    ld = os.path.join(out, "adc_trng_api.ld")
    with open(ld, "w") as f:
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
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", obj, src], cwd=REPO)
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld, "-nostdlib", "-o", elf, obj])
    return elf


def _load(elf):
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    return sim


def _call(sim, name, *args, max_steps=200_000):
    park = sim.symbol("_park")
    func = sim.symbol(name)
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
    for i, v in enumerate(args):
        sim.uc.reg_write(regs[i], v & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=max_steps)


def _writes_at(sim, addr):
    return [w for w in sim.writes if w.addr == addr]


# ----- ADC ------------------------------------------------------------------


def test_adc_init_clears_resets_and_waits_ready(fixture_elf):
    sim = _load(fixture_elf)
    # Mock CS read to return EN|READY immediately
    sim.on_read(ADC_CS, 4, lambda a, s: CS_EN | CS_READY)
    _call(sim, "adc_init")
    rs = _writes_at(sim, RESETS_RESET_CLR)
    assert rs and rs[0].value == (1 << 0), f"adc RESETS bit not cleared: {rs}"
    csw = _writes_at(sim, ADC_CS)
    assert csw and csw[-1].value == CS_EN


def test_adc_set_clkdiv_packs_int_and_frac(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "adc_set_clkdiv", 96, 0x12)
    w = _writes_at(sim, ADC_DIV)
    assert w and w[-1].value == ((96 << 8) | 0x12)


def test_adc_select_input_sets_ainsel(fixture_elf):
    sim = _load(fixture_elf)
    sim.on_read(ADC_CS, 4, lambda a, s: CS_EN)  # current CS value with no AINSEL
    _call(sim, "adc_select_input", 3)
    w = _writes_at(sim, ADC_CS)
    assert w
    assert (w[-1].value >> CS_AINSEL_SHIFT) & 0xF == 3
    # EN preserved
    assert w[-1].value & CS_EN


def test_adc_read_start_once_then_polls_ready(fixture_elf):
    sim = _load(fixture_elf)
    polls = [0]
    def cs_read(addr, size):
        polls[0] += 1
        # First call (before START_ONCE store) returns 0; later calls return READY
        return CS_READY if polls[0] >= 2 else 0
    sim.on_read(ADC_CS, 4, cs_read)
    sim.on_read(ADC_RESULT, 4, lambda a, s: 0xABC)
    _call(sim, "adc_read")
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0xABC
    # Must have written CS with START_ONCE bit set at some point
    cs_writes = _writes_at(sim, ADC_CS)
    assert any(w.value & CS_START_ONCE for w in cs_writes), f"START_ONCE never set: {cs_writes}"


# ----- TRNG -----------------------------------------------------------------


def test_trng_init_enables_random_source(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "trng_init")
    rs = _writes_at(sim, RESETS_RESET_CLR)
    assert rs and rs[0].value == (1 << 25), f"trng RESETS bit: {rs}"
    en = _writes_at(sim, TRNG_RND_SOURCE_ENABLE)
    assert en and en[-1].value == 1


def test_trng_get_random_word_polls_valid_then_reads(fixture_elf):
    sim = _load(fixture_elf)
    polls = [0]
    def valid_read(addr, size):
        polls[0] += 1
        return 1 if polls[0] >= 3 else 0
    sim.on_read(TRNG_VALID, 4, valid_read)
    sim.on_read(TRNG_EHR_DATA0, 4, lambda a, s: 0xDEADBEEF)
    _call(sim, "trng_get_random_word")
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0xDEADBEEF
    # ICR must be written to release the EHR
    icr = _writes_at(sim, TRNG_RNG_ICR)
    assert icr and icr[-1].value & 1
