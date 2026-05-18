# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 tests for src/sched_stats.S - per-task DWT cycle accounting."""

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

# Stats block layout (mirrors src/sched_stats.S)
STATS_OFF_FN = 0
STATS_OFF_TOTAL = 4
STATS_OFF_INVOC = 8
STATS_OFF_MAX = 12
STATS_STRIDE = 16

DWT_BASE = 0xE0001000
DWT_CYCCNT = DWT_BASE + 0x004
SCB_VTOR = 0xE000ED08


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("stats_fixture")
    src = os.path.join(HERE, "fixtures", "sched_stats_api.S")
    obj = os.path.join(out, "sched_stats_api.o")
    elf = os.path.join(out, "sched_stats_api.elf")
    ld = os.path.join(out, "sched_stats_api.ld")
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
  .bss : {{ *(.bss*) }} > SRAM
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
    vectors = sim.symbol("_vectors")
    sim.poke32(SCB_VTOR, vectors)
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


def _slot_addr(sim, task_id):
    return sim.symbol("task_stats") + task_id * STATS_STRIDE


def _mock_dwt_advancing(sim, step=100):
    """DWT.CYCCNT returns a counter that advances `step` cycles per read.
    Lets us predict the delta the trampoline computes (one read before
    the user fn, one after = delta of `step`)."""
    counter = [0]

    def cb(addr, size):
        v = counter[0]
        counter[0] += step
        return v

    sim.on_read(DWT_CYCCNT, 4, cb)


# ---------------------------------------------------------------------------


def test_task_create_traced_stores_fn(fixture_elf):
    """task_create_traced(id=2, fn=fake_user_fn, prio=0x40) writes the
    user fn (Thumb-encoded) into task_stats[2].fn."""
    sim = _load(fixture_elf)
    fn = sim.symbol("fake_user_fn")
    _call(sim, "task_create_traced", 2, fn, 0x40)
    stored = sim.peek32(_slot_addr(sim, 2) + STATS_OFF_FN)
    assert stored == (fn | 1), \
        f"task_stats[2].fn = {stored:#x}, expected {fn | 1:#x}"


def test_trampoline_records_delta_into_total(fixture_elf):
    """Run _task_tramp_0 directly; with DWT mocked to advance 100 cycles
    per read, the trampoline should see delta=100 and add it to
    task_stats[0].cycles_total."""
    sim = _load(fixture_elf)
    # Install fn so the trampoline has something to call.  We use the
    # public API so we exercise it too.
    _call(sim, "task_create_traced", 0, sim.symbol("fake_user_fn"), 0)

    _mock_dwt_advancing(sim, step=100)

    # Invoke the trampoline directly (as if NVIC dispatched the task).
    _call(sim, "_task_tramp_0", max_steps=200_000)

    total = sim.peek32(_slot_addr(sim, 0) + STATS_OFF_TOTAL)
    invoc = sim.peek32(_slot_addr(sim, 0) + STATS_OFF_INVOC)
    maxc = sim.peek32(_slot_addr(sim, 0) + STATS_OFF_MAX)
    assert total == 100, f"cycles_total: {total}"
    assert invoc == 1, f"invocations: {invoc}"
    assert maxc == 100, f"max_cycles: {maxc}"


def test_trampoline_accumulates_over_invocations(fixture_elf):
    """Two invocations: cycles_total grows; max_cycles holds the worst case."""
    sim = _load(fixture_elf)
    _call(sim, "task_create_traced", 3, sim.symbol("fake_user_fn"), 0)

    # First call: delta = 50
    _mock_dwt_advancing(sim, step=50)
    _call(sim, "_task_tramp_3")

    # We need a different rate now; clear hooks and re-register
    sim._read_hooks.clear()
    _mock_dwt_advancing(sim, step=200)
    _call(sim, "_task_tramp_3")

    total = sim.peek32(_slot_addr(sim, 3) + STATS_OFF_TOTAL)
    invoc = sim.peek32(_slot_addr(sim, 3) + STATS_OFF_INVOC)
    maxc = sim.peek32(_slot_addr(sim, 3) + STATS_OFF_MAX)
    assert total == 250, f"cycles_total: {total} (expected 50+200)"
    assert invoc == 2, f"invocations: {invoc}"
    assert maxc == 200, f"max_cycles: {maxc} (expected max(50, 200))"


def test_task_stats_total_getter(fixture_elf):
    sim = _load(fixture_elf)
    sim.poke32(_slot_addr(sim, 5) + STATS_OFF_TOTAL, 0xDEADBEEF)
    _call(sim, "task_stats_total", 5)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0xDEADBEEF


def test_task_stats_invocations_getter(fixture_elf):
    sim = _load(fixture_elf)
    sim.poke32(_slot_addr(sim, 4) + STATS_OFF_INVOC, 1234)
    _call(sim, "task_stats_invocations", 4)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1234


def test_task_stats_max_getter(fixture_elf):
    sim = _load(fixture_elf)
    sim.poke32(_slot_addr(sim, 6) + STATS_OFF_MAX, 4242)
    _call(sim, "task_stats_max", 6)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 4242


def test_task_stats_reset_preserves_fn(fixture_elf):
    sim = _load(fixture_elf)
    base = _slot_addr(sim, 2)
    sim.poke32(base + STATS_OFF_FN, 0x20001235)
    sim.poke32(base + STATS_OFF_TOTAL, 999)
    sim.poke32(base + STATS_OFF_INVOC, 42)
    sim.poke32(base + STATS_OFF_MAX, 100)
    _call(sim, "task_stats_reset", 2)
    assert sim.peek32(base + STATS_OFF_FN) == 0x20001235, \
        "task_stats_reset must NOT clear fn"
    assert sim.peek32(base + STATS_OFF_TOTAL) == 0
    assert sim.peek32(base + STATS_OFF_INVOC) == 0
    assert sim.peek32(base + STATS_OFF_MAX) == 0


def test_task_stats_reset_all_clears_every_slot(fixture_elf):
    sim = _load(fixture_elf)
    for i in range(8):
        base = _slot_addr(sim, i)
        sim.poke32(base + STATS_OFF_FN, 0xDEAD0000 | i)
        sim.poke32(base + STATS_OFF_TOTAL, 100 * (i + 1))
        sim.poke32(base + STATS_OFF_INVOC, i + 1)
        sim.poke32(base + STATS_OFF_MAX, 50 * (i + 1))
    _call(sim, "task_stats_reset_all")
    for i in range(8):
        base = _slot_addr(sim, i)
        assert sim.peek32(base + STATS_OFF_FN) == (0xDEAD0000 | i), \
            f"slot {i} fn clobbered"
        assert sim.peek32(base + STATS_OFF_TOTAL) == 0
        assert sim.peek32(base + STATS_OFF_INVOC) == 0
        assert sim.peek32(base + STATS_OFF_MAX) == 0
