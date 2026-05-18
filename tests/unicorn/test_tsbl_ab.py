# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 tests for src/tsbl/tsbl_ab.S - the A/B slot-selection logic.

Exercises tsbl_ab_select as a pure function across the entire decision
truth table: rollback overrides, both-valid-pick-by-seq, one-valid-pick-it,
neither-valid-halt. Footer pointers are placed in SRAM; the .seq field at
offset 0x70 is the only thing tsbl_ab_select reads from them.
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
from unicorn.arm_const import (  # noqa: E402
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2,
    UC_ARM_REG_LR, UC_ARM_REG_PC,
)

# Mirrors include/bootloader.inc.
BL_FOOTER_OFF_SEQ = 0x70
BL_SCRATCH_AB_TRY_A = 0xB001AB0A
BL_SCRATCH_AB_TRY_B = 0xB001AB0B

# Where we place synthetic footers in SRAM.
FOOTER_A_ADDR = SRAM_BASE + 0x2000
FOOTER_B_ADDR = SRAM_BASE + 0x2100


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("tsbl_ab_fixture")
    src = os.path.join(HERE, "fixtures", "tsbl_ab_api.S")
    obj = os.path.join(out, "tsbl_ab_api.o")
    elf = os.path.join(out, "tsbl_ab_api.elf")
    ld = os.path.join(out, "tsbl_ab_api.ld")
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


def _call_select(elf, footer_a: int, footer_b: int, scratch6: int) -> int:
    """Call tsbl_ab_select(r0=footer_a, r1=footer_b, r2=scratch6); return r0."""
    sim = RP2350Sim()
    sim.load_elf(elf)
    park = sim.symbol("_park")
    func = sim.symbol("tsbl_ab_select")

    # Plant synthetic footers if the test wants them readable. The function
    # only touches the .seq field at +0x70 so we can leave the rest as
    # whatever the SRAM was initialised to.
    sim.uc.reg_write(UC_ARM_REG_R0, footer_a & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_R1, footer_b & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_R2, scratch6 & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=200)
    return sim.uc.reg_read(UC_ARM_REG_R0)


def _plant_seq(sim_or_uc, addr: int, seq: int) -> None:
    """Write a u32 seq value at addr + 0x70."""
    sim_or_uc.mem_write(addr + BL_FOOTER_OFF_SEQ, struct.pack("<I", seq))


def _call_select_with_seqs(elf, a_valid: bool, a_seq: int,
                            b_valid: bool, b_seq: int,
                            scratch6: int) -> int:
    sim = RP2350Sim()
    sim.load_elf(elf)

    if a_valid:
        _plant_seq(sim.uc, FOOTER_A_ADDR, a_seq)
        a_ptr = FOOTER_A_ADDR
    else:
        a_ptr = 0
    if b_valid:
        _plant_seq(sim.uc, FOOTER_B_ADDR, b_seq)
        b_ptr = FOOTER_B_ADDR
    else:
        b_ptr = 0

    park = sim.symbol("_park")
    func = sim.symbol("tsbl_ab_select")
    sim.uc.reg_write(UC_ARM_REG_R0, a_ptr & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_R1, b_ptr & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_R2, scratch6 & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=200)
    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    # Reinterpret as signed: -1 is 0xFFFFFFFF.
    return r0 if r0 < 0x80000000 else r0 - 0x100000000


# (a_valid, a_seq, b_valid, b_seq, scratch6, expected)
# expected: 0 = boot A, 1 = boot B, -1 = halt
CASES = [
    # ---- Normal cold-boot selection (scratch=0) ----
    ("both valid, A higher seq",       True, 7,  True, 3,  0,                   0),
    ("both valid, B higher seq",       True, 3,  True, 7,  0,                   1),
    ("both valid, equal seq tie -> A", True, 5,  True, 5,  0,                   0),
    ("only A valid",                   True, 1,  False, 0, 0,                   0),
    ("only B valid",                   False, 0, True, 1,  0,                   1),
    ("neither valid",                  False, 0, False, 0, 0,                  -1),
    # ---- Rollback: A was last attempt, A failed -> B ----
    ("rollback TRY_A, B valid",        True, 9,  True, 1,  BL_SCRATCH_AB_TRY_A, 1),
    ("rollback TRY_A, B invalid -> halt", True, 9, False, 0, BL_SCRATCH_AB_TRY_A, -1),
    # ---- Rollback: B was last attempt, B failed -> A ----
    ("rollback TRY_B, A valid",        True, 1,  True, 9,  BL_SCRATCH_AB_TRY_B, 0),
    ("rollback TRY_B, A invalid -> halt", False, 0, True, 9, BL_SCRATCH_AB_TRY_B, -1),
    # ---- Rollback markers with the targeted slot missing ----
    ("rollback TRY_A, only A valid -> halt", True, 5, False, 0, BL_SCRATCH_AB_TRY_A, -1),
    ("rollback TRY_B, only B valid -> halt", False, 0, True, 5, BL_SCRATCH_AB_TRY_B, -1),
]


@pytest.mark.parametrize("desc,a_valid,a_seq,b_valid,b_seq,scratch6,expected", CASES)
def test_select(fixture_elf, desc, a_valid, a_seq, b_valid, b_seq,
                 scratch6, expected):
    got = _call_select_with_seqs(
        fixture_elf, a_valid, a_seq, b_valid, b_seq, scratch6)
    assert got == expected, (
        f"{desc}: got {got}, expected {expected}"
    )


def test_unrecognised_scratch_is_normal_boot(fixture_elf):
    """A scratch value that isn't TRY_A or TRY_B should fall through to
    the normal-selection path - we don't want a garbage scratch to brick
    the rollback decision."""
    # Both slots valid, B has higher seq. Garbage scratch 0xDEADBEEF.
    got = _call_select_with_seqs(
        fixture_elf, True, 1, True, 2, 0xDEADBEEF)
    assert got == 1
