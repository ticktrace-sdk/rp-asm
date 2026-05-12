"""T1 tests for src/sched.S - the NVIC-priority kernel (QV-style).

Tasks live on NVIC IRQ lines starting at SCHED_BASE_IRQ (48 by default).
NVIC regs live in the PPB region (0xE000_0000+) which the harness
pre-maps, so no special mem_map setup is required.
"""

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

# ---------------------------------------------------------------- constants
SCHED_BASE_IRQ = 48
NVIC_ISER_BASE = 0xE000E100
NVIC_ICER_BASE = 0xE000E180
NVIC_ISPR_BASE = 0xE000E200
NVIC_ICPR_BASE = 0xE000E280
NVIC_IPR_BASE = 0xE000E400
SCB_SCR = 0xE000ED10
SCB_SCR_SEVONPEND = 1 << 4


def _bank(irq):
    return irq // 32


def _bit(irq):
    return 1 << (irq % 32)


# ----------------------------------------------------------------- fixtures


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("sched_fixture")
    src = os.path.join(HERE, "fixtures", "sched_api.S")
    obj = os.path.join(out, "sched_api.o")
    elf = os.path.join(out, "sched_api.elf")
    ld = os.path.join(out, "sched_api.ld")
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


SCB_VTOR = 0xE000ED08


def _load(elf):
    sim = RP2350Sim()
    sim.load_elf(elf)
    # nvic_install_handler reads VTOR to find the vector table.  Point
    # it at the fixture's _vectors (which lives at SRAM_BASE).
    vectors = sim.symbol("_vectors")
    sim.poke32(SCB_VTOR, vectors)
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


# ---------------------------------------------------------------- sched_init


def test_sched_init_sets_sevonpend(fixture_elf):
    sim = _load(fixture_elf)
    sim.poke32(SCB_SCR, 0)
    _call(sim, "sched_init")
    w = _writes_at(sim, SCB_SCR)
    assert w and (w[-1].value & SCB_SCR_SEVONPEND), \
        f"SEVONPEND not set in SCR: {w}"


def test_sched_init_clears_pending_in_task_range(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "sched_init")
    # IRQs 48..55 live in NVIC bank 1 (32..63), bits 16..23. We write
    # 0x00FF0000 to ICPR1 to clear them.
    w = _writes_at(sim, NVIC_ICPR_BASE + 4)
    assert w and w[-1].value == 0x00FF0000, f"ICPR1 mask: {w}"


# ---------------------------------------------------------------- task_create


def test_task_create_installs_vector_sets_prio_enables_nvic(fixture_elf):
    """task_create(id=2, fn=0x20001234, prio=0x80):
       - Vector at _vectors + (16 + 50) * 4 = _vectors + 264 must hold fn|1
       - NVIC_IPR[50] (byte) must equal 0x80
       - NVIC_ISER1 bit (50%32=18) must be set"""
    sim = _load(fixture_elf)
    HANDLER = 0x20001234
    _call(sim, "task_create", 2, HANDLER, 0x80)

    # Vector slot
    vectors_base = sim.symbol("_vectors")
    irq = SCHED_BASE_IRQ + 2
    vec_addr = vectors_base + (16 + irq) * 4
    written = sim.peek32(vec_addr)
    assert written == (HANDLER | 1), \
        f"vector slot @ {vec_addr:#x} = {written:#x}, expected {HANDLER | 1:#x}"

    # Priority byte
    ipr_addr = NVIC_IPR_BASE + irq
    # Find the strb to this exact byte address.
    prio_writes = [w for w in sim.writes if w.addr == ipr_addr and w.size == 1]
    assert prio_writes and prio_writes[-1].value == 0x80, \
        f"strb @ {ipr_addr:#x}: {prio_writes}"

    # NVIC ISER bank 1 enable bit 18
    iser_addr = NVIC_ISER_BASE + _bank(irq) * 4
    iser_writes = [w for w in sim.writes if w.addr == iser_addr]
    assert iser_writes and iser_writes[-1].value == _bit(irq), \
        f"ISER @ {iser_addr:#x}: {iser_writes}"


def test_task_create_id0_lands_on_base_irq(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "task_create", 0, 0xDEAD0000, 0)
    # IRQ = 48 -> bank 1, bit 16
    iser_addr = NVIC_ISER_BASE + 1 * 4
    iser = [w for w in sim.writes if w.addr == iser_addr]
    assert iser and iser[-1].value == (1 << 16)


# ---------------------------------------------------------------- task_post


def test_task_post_id0_writes_ispr_bank1_bit16(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "task_post", 0)
    ispr_addr = NVIC_ISPR_BASE + 4  # bank 1
    w = _writes_at(sim, ispr_addr)
    assert w and w[-1].value == (1 << 16), \
        f"task_post(0) -> ISPR1: {w}"


def test_task_post_id7_writes_ispr_bank1_bit23(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "task_post", 7)
    ispr_addr = NVIC_ISPR_BASE + 4
    w = _writes_at(sim, ispr_addr)
    assert w and w[-1].value == (1 << 23), \
        f"task_post(7) -> ISPR1: {w}"


def test_task_post_is_single_store(fixture_elf):
    """The point of this kernel is that task_post is one store.
    Make sure it really is (not counting the literal-pool ldr)."""
    sim = _load(fixture_elf)
    _call(sim, "task_post", 3)
    # Exactly 1 write to the PPB ISPR region
    ppb_writes = [w for w in sim.writes
                  if NVIC_ISPR_BASE <= w.addr < NVIC_ISPR_BASE + 0x80]
    assert len(ppb_writes) == 1, \
        f"task_post should be a single store; got {ppb_writes}"


# ---------------------------------------------------------------- task_clear


def test_task_clear_writes_icpr(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "task_clear", 4)
    icpr_addr = NVIC_ICPR_BASE + 4  # bank 1
    w = _writes_at(sim, icpr_addr)
    irq = SCHED_BASE_IRQ + 4
    assert w and w[-1].value == _bit(irq)


# ---------------------------------------------------------------- critical


# ---------------------------------------------------------------- task_post_n


def test_task_post_n_posts_multiple_tasks_in_one_store(fixture_elf):
    """task_post_n(0x05) = post tasks 0 and 2 in one STR.
    SCHED_BASE_IRQ=48 means bits 16 and 18 of NVIC_ISPR1."""
    sim = _load(fixture_elf)
    _call(sim, "task_post_n", 0x05)
    ispr_addr = NVIC_ISPR_BASE + 4
    w = _writes_at(sim, ispr_addr)
    assert len(w) == 1, f"task_post_n must be a single store, got: {w}"
    expected = (1 << 16) | (1 << 18)
    assert w[-1].value == expected, \
        f"task_post_n(0x05): expected ISPR1 = {expected:#x}, got {w[-1].value:#x}"


def test_task_post_n_clamps_to_max_tasks(fixture_elf):
    """Bits beyond MAX_TASKS (id >= 8) must be ignored; the implementation
    AND-masks before shifting."""
    sim = _load(fixture_elf)
    _call(sim, "task_post_n", 0xFFFFFFFF)
    ispr_addr = NVIC_ISPR_BASE + 4
    w = _writes_at(sim, ispr_addr)
    # All 8 tasks: bits 16..23
    assert w and w[-1].value == 0x00FF0000, \
        f"task_post_n(all): expected 0x00FF0000, got {w[-1].value:#x}"


# ---------------------------------------------------------------- BASEPRI


def test_critical_enter_basepri_round_trip(fixture_elf):
    """enter returns previous BASEPRI (0 at boot); exit restores."""
    sim = _load(fixture_elf)
    _call(sim, "critical_enter_basepri", 0x40)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0, \
        f"enter_basepri(0x40) returned {sim.uc.reg_read(UC_ARM_REG_R0):#x}, expected 0"

    _call(sim, "critical_exit_basepri", 0)
    # No trap == pass; BASEPRI not exposed through Unicorn's standard regs.


def test_critical_enter_exit_round_trips_primask(fixture_elf):
    """critical_enter returns the previous PRIMASK; critical_exit restores it."""
    sim = _load(fixture_elf)
    # PRIMASK starts at 0 (IRQs not masked).  After critical_enter,
    # r0 should be 0 (the previous value).
    _call(sim, "critical_enter")
    saved = sim.uc.reg_read(UC_ARM_REG_R0)
    assert saved == 0, f"critical_enter returned {saved:#x}, expected 0"

    # critical_exit(0) should leave PRIMASK at 0; calling it after the
    # enter sequence ensures we don't leave IRQs masked.
    _call(sim, "critical_exit", 0)
    # No assertion against PRIMASK directly (Unicorn doesn't expose it
    # via reg_read for ARMv7-M ABI in our setup); the smoke test that
    # the function returns without trapping is enough here.
