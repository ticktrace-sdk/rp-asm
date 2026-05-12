"""T1 tests for src/spsc.S - the SPSC byte queue."""

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

# Queue layout (matches include/spsc.inc)
SPSC_HEAD = 0
SPSC_TAIL = 4
SPSC_MASK = 8
SPSC_DATA = 16

# log2size = 4 -> 16-byte buffer, 15-byte capacity
TEST_Q_SIZE = 16
TEST_Q_MASK = TEST_Q_SIZE - 1


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("spsc_fixture")
    src = os.path.join(HERE, "fixtures", "spsc_api.S")
    obj = os.path.join(out, "spsc_api.o")
    elf = os.path.join(out, "spsc_api.elf")
    ld = os.path.join(out, "spsc_api.ld")
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


def _q(sim):
    return sim.symbol("test_q")


def _seed_queue(sim):
    """Reset the queue: head = tail = 0; mask = TEST_Q_MASK."""
    q = _q(sim)
    sim.poke32(q + SPSC_HEAD, 0)
    sim.poke32(q + SPSC_TAIL, 0)
    sim.poke32(q + SPSC_MASK, TEST_Q_MASK)


# -----------------------------------------------------------------------------


def test_push_then_pop_round_trips(fixture_elf):
    sim = _load(fixture_elf)
    _seed_queue(sim)
    _call(sim, "spsc_byte_push", _q(sim), 0xAB)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1
    _call(sim, "spsc_byte_pop", _q(sim))
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0xAB


def test_pop_empty_returns_neg1(fixture_elf):
    sim = _load(fixture_elf)
    _seed_queue(sim)
    _call(sim, "spsc_byte_pop", _q(sim))
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0xFFFFFFFF


def test_fifo_order_preserved(fixture_elf):
    sim = _load(fixture_elf)
    _seed_queue(sim)
    for v in (1, 2, 3, 4, 5):
        _call(sim, "spsc_byte_push", _q(sim), v)
        assert sim.uc.reg_read(UC_ARM_REG_R0) == 1
    out = []
    for _ in range(5):
        _call(sim, "spsc_byte_pop", _q(sim))
        out.append(sim.uc.reg_read(UC_ARM_REG_R0))
    assert out == [1, 2, 3, 4, 5]


def test_push_returns_0_when_full(fixture_elf):
    """Capacity is size - 1 = 15.  16th push must report failure."""
    sim = _load(fixture_elf)
    _seed_queue(sim)
    for i in range(TEST_Q_SIZE - 1):
        _call(sim, "spsc_byte_push", _q(sim), i)
        assert sim.uc.reg_read(UC_ARM_REG_R0) == 1
    # The next push should fail.
    _call(sim, "spsc_byte_push", _q(sim), 99)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0
    # And head must not advance past tail
    head = sim.peek32(_q(sim) + SPSC_HEAD)
    tail = sim.peek32(_q(sim) + SPSC_TAIL)
    # Either head + 1 == tail or both wrapped around; in this case
    # tail=0, head=15 (since we pushed 15 from head=0 successfully).
    assert (head + 1) & TEST_Q_MASK == tail, \
        f"head={head}, tail={tail}, mask={TEST_Q_MASK}"


def test_wraparound_works(fixture_elf):
    """Pushing past the end and popping must keep FIFO order."""
    sim = _load(fixture_elf)
    _seed_queue(sim)
    # Push 10
    for v in range(10):
        _call(sim, "spsc_byte_push", _q(sim), v)
    # Pop 8
    for v in range(8):
        _call(sim, "spsc_byte_pop", _q(sim))
        assert sim.uc.reg_read(UC_ARM_REG_R0) == v
    # Push 8 more — they should land past the wrap
    for v in range(20, 28):
        _call(sim, "spsc_byte_push", _q(sim), v)
        assert sim.uc.reg_read(UC_ARM_REG_R0) == 1
    # Now pop all 10 remaining
    expected = [8, 9, 20, 21, 22, 23, 24, 25, 26, 27]
    actual = []
    for _ in expected:
        _call(sim, "spsc_byte_pop", _q(sim))
        actual.append(sim.uc.reg_read(UC_ARM_REG_R0))
    assert actual == expected


def test_count_matches_actual(fixture_elf):
    sim = _load(fixture_elf)
    _seed_queue(sim)
    _call(sim, "spsc_byte_count", _q(sim))
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0
    for v in range(7):
        _call(sim, "spsc_byte_push", _q(sim), v)
    _call(sim, "spsc_byte_count", _q(sim))
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 7
    for _ in range(3):
        _call(sim, "spsc_byte_pop", _q(sim))
    _call(sim, "spsc_byte_count", _q(sim))
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 4


def test_spsc_reset(fixture_elf):
    sim = _load(fixture_elf)
    _seed_queue(sim)
    for v in range(5):
        _call(sim, "spsc_byte_push", _q(sim), v)
    _call(sim, "spsc_reset", _q(sim))
    assert sim.peek32(_q(sim) + SPSC_HEAD) == 0
    assert sim.peek32(_q(sim) + SPSC_TAIL) == 0
    _call(sim, "spsc_byte_count", _q(sim))
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0


def test_byte_only_low_8_bits(fixture_elf):
    """spsc_byte_push must only store the low 8 bits even if a wider value
    is in r1.  The strb in the implementation guarantees this."""
    sim = _load(fixture_elf)
    _seed_queue(sim)
    _call(sim, "spsc_byte_push", _q(sim), 0xDEADBE5A)
    _call(sim, "spsc_byte_pop", _q(sim))
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0x5A
