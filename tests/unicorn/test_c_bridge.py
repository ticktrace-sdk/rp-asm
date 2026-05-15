# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 tests for c_bridge/asm_libc.S and c_bridge/runtime.S.

These primitives only get exercised when a C app links against them, so
we drive them directly via the harness to keep the C bridge honest."""

import os
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


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("c_bridge_fixture")
    src = os.path.join(HERE, "fixtures", "c_bridge_api.S")
    obj = os.path.join(out, "c_bridge_api.o")
    elf = os.path.join(out, "c_bridge_api.elf")
    ld = os.path.join(out, "c_bridge_api.ld")
    with open(ld, "w") as f:
        f.write(f"""ENTRY(_start)
MEMORY {{ SRAM(rwx) : ORIGIN = {hex(SRAM_BASE)}, LENGTH = 64K }}
SECTIONS {{
  .text {hex(SRAM_BASE)} : {{
    KEEP(*(.vectors))
    *(.text._start)
    *(.text*)
    *(.rodata*)
    *(.data*)
  }} > SRAM
  _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;
}}
""")
    asflags = ["-mcpu=cortex-m33", "-mthumb", "-mimplicit-it=always",
               "-I", os.path.join(REPO, "include"),
               "-I", REPO]
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", obj, src], cwd=REPO)
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld, "-nostdlib", "-o", elf, obj])
    return elf


def _load(elf):
    sim = RP2350Sim()
    sim.load_elf(elf)
    return sim


def _call(sim, name, *args, max_steps=500_000):
    park = sim.symbol("_park")
    func = sim.symbol(name)
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
    for i, v in enumerate(args):
        sim.uc.reg_write(regs[i], v & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=max_steps)


# ---------------------------------------------------------------- memset


def test_memset_zeroes_aligned_buffer(fixture_elf):
    sim = _load(fixture_elf)
    BUF = SRAM_BASE + 0xD000
    # Pre-fill with 0xAA
    sim.uc.mem_write(BUF, b"\xAA" * 64)
    _call(sim, "memset", BUF, 0x00, 64)
    out = bytes(sim.uc.mem_read(BUF, 64))
    assert out == b"\x00" * 64
    # Returns the destination pointer
    assert sim.uc.reg_read(UC_ARM_REG_R0) == BUF


def test_memset_byte_value_replicates(fixture_elf):
    sim = _load(fixture_elf)
    BUF = SRAM_BASE + 0xD000
    _call(sim, "memset", BUF, 0x5A, 32)
    out = bytes(sim.uc.mem_read(BUF, 32))
    assert out == b"\x5A" * 32


def test_memset_handles_unaligned_count(fixture_elf):
    sim = _load(fixture_elf)
    BUF = SRAM_BASE + 0xD000
    sim.uc.mem_write(BUF, b"\xFF" * 16)
    _call(sim, "memset", BUF, 0x42, 13)        # not a multiple of 4
    out = bytes(sim.uc.mem_read(BUF, 16))
    assert out[:13] == b"\x42" * 13
    assert out[13:] == b"\xFF" * 3              # past `n` untouched


# ---------------------------------------------------------------- memcpy


def test_memcpy_word_aligned(fixture_elf):
    sim = _load(fixture_elf)
    SRC = SRAM_BASE + 0xD000
    DST = SRAM_BASE + 0xE000
    payload = bytes(range(64))
    sim.uc.mem_write(SRC, payload)
    sim.uc.mem_write(DST, b"\x00" * 64)
    _call(sim, "memcpy", DST, SRC, 64)
    assert bytes(sim.uc.mem_read(DST, 64)) == payload
    assert sim.uc.reg_read(UC_ARM_REG_R0) == DST


def test_memcpy_byte_path_for_unaligned_count(fixture_elf):
    sim = _load(fixture_elf)
    SRC = SRAM_BASE + 0xD000
    DST = SRAM_BASE + 0xE000
    payload = bytes(range(50, 50 + 17))
    sim.uc.mem_write(SRC, payload)
    sim.uc.mem_write(DST, b"\x00" * 32)
    _call(sim, "memcpy", DST, SRC, 17)
    out = bytes(sim.uc.mem_read(DST, 32))
    assert out[:17] == payload
    assert out[17:] == b"\x00" * 15


# ---------------------------------------------------------------- memcmp


def test_memcmp_equal_returns_zero(fixture_elf):
    sim = _load(fixture_elf)
    A = SRAM_BASE + 0xD000
    B = SRAM_BASE + 0xE000
    sim.uc.mem_write(A, b"hello rp-asm")
    sim.uc.mem_write(B, b"hello rp-asm")
    _call(sim, "memcmp", A, B, 12)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0


def test_memcmp_first_mismatch_signed(fixture_elf):
    sim = _load(fixture_elf)
    A = SRAM_BASE + 0xD000
    B = SRAM_BASE + 0xE000
    sim.uc.mem_write(A, b"abcZ")
    sim.uc.mem_write(B, b"abcA")
    _call(sim, "memcmp", A, B, 4)
    # 'Z' (0x5A) - 'A' (0x41) = 0x19 = 25
    r = sim.uc.reg_read(UC_ARM_REG_R0)
    # cast to signed since memcmp returns int
    assert (r & 0xFFFFFFFF) == 25


# ---------------------------------------------------------------- _c_runtime_init


def test_c_runtime_init_zeroes_bss(fixture_elf):
    """The fixture declares __bss_start__/__bss_end__ around a 64-byte
    region.  Pre-fill it with garbage, call _c_runtime_init, expect
    zeros."""
    sim = _load(fixture_elf)
    bss_start = sim.symbol("__bss_start__")
    bss_end = sim.symbol("__bss_end__")
    span = bss_end - bss_start
    sim.uc.mem_write(bss_start, b"\xDE" * span)
    _call(sim, "_c_runtime_init")
    out = bytes(sim.uc.mem_read(bss_start, span))
    assert out == b"\x00" * span, \
        f"_c_runtime_init left non-zero bytes: {out[:16]}..."
