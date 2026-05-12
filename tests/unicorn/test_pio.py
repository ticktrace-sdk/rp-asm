"""T1 tests for the M5-I PIO controller driver.

PIO lives at 0x50200000..0x50404000 which is *outside* the harness's APB
pre-mapping (0x40000000..0x4FFFFFFF).  `_map_pio` adds the region plus the
sim's MMIO recording hooks before each test so `sim.writes` sees PIO
traffic.
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
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
    UC_ARM_REG_LR, UC_ARM_REG_PC,
)

PIO0_BASE = 0x50200000
PIO1_BASE = 0x50300000
PIO2_BASE = 0x50400000

PIO_CTRL = 0x000
PIO_FSTAT = 0x004
PIO_TXF0 = 0x010
PIO_RXF0 = 0x020
PIO_INSTR_MEM0 = 0x048
PIO_SM0_CLKDIV = 0x0C8
PIO_SM0_EXECCTRL = 0x0CC
PIO_SM0_INSTR = 0x0D8
PIO_SM0_PINCTRL = 0x0DC
PIO_SM_STRIDE = 0x018

RESETS_BASE = 0x40020000
RESETS_RESET_CLR = RESETS_BASE + 0x3000

# Big window covering PIO0..PIO2 (0x50200000..0x504040FF) plus all atomic
# alias windows.  Page-aligned size for Unicorn's 4 KiB page granularity.
PIO_MAP_BASE = 0x50200000
PIO_MAP_SIZE = 0x00210000


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("pio_fixture")
    src = os.path.join(HERE, "fixtures", "pio_api.S")
    obj = os.path.join(out, "pio_api.o")
    elf = os.path.join(out, "pio_api.elf")
    ld = os.path.join(out, "pio_api.ld")
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


def _map_pio(sim):
    """Map and instrument the 0x50200000+ window. Idempotent."""
    from unicorn import UC_PROT_READ, UC_PROT_WRITE
    from unicorn import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
    try:
        sim.uc.mem_map(PIO_MAP_BASE, PIO_MAP_SIZE,
                       UC_PROT_READ | UC_PROT_WRITE)
    except Exception:
        # Already mapped (e.g. a previous test in the same sim); fine.
        pass
    # Recording hooks so sim.writes/sim.on_read see PIO traffic.
    sim.uc.hook_add(UC_HOOK_MEM_WRITE, sim._on_write,
                    begin=PIO_MAP_BASE,
                    end=PIO_MAP_BASE + PIO_MAP_SIZE - 1)
    sim.uc.hook_add(UC_HOOK_MEM_READ, sim._on_read,
                    begin=PIO_MAP_BASE,
                    end=PIO_MAP_BASE + PIO_MAP_SIZE - 1)


def _load(elf):
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    _map_pio(sim)
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


def test_pio_init_clears_correct_resets_bit(fixture_elf):
    """pio_init(0) clears RESETS bit 11 (pio0); pio_init(2) clears bit 13 (pio2)."""
    sim = _load(fixture_elf)
    _call(sim, "pio_init", 0)
    rs = _writes_at(sim, RESETS_RESET_CLR)
    assert rs and rs[0].value == (1 << 11), f"pio0: {rs}"

    sim = _load(fixture_elf)
    _call(sim, "pio_init", 2)
    rs = _writes_at(sim, RESETS_RESET_CLR)
    assert rs and rs[0].value == (1 << 13), f"pio2: {rs}"


def test_pio_add_program_copies_to_instr_mem(fixture_elf):
    """3-word program lands at INSTR_MEM[0..2] when origin=0."""
    sim = _load(fixture_elf)
    PROG = SRAM_BASE + 0xD000
    sim.uc.mem_write(PROG, struct.pack("<III", 0xFF01, 0xFF00, 0x0000))
    _call(sim, "pio_add_program", 0, PROG, 3, 0)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0

    base = PIO0_BASE + PIO_INSTR_MEM0
    for i, expected in enumerate([0xFF01, 0xFF00, 0x0000]):
        w = _writes_at(sim, base + i * 4)
        assert w and w[-1].value == expected, f"instr[{i}] writes: {w}"


def test_pio_add_program_honours_origin(fixture_elf):
    """origin=5 places the first word at INSTR_MEM[5]."""
    sim = _load(fixture_elf)
    PROG = SRAM_BASE + 0xD000
    sim.uc.mem_write(PROG, struct.pack("<I", 0xDEAD))
    _call(sim, "pio_add_program", 1, PROG, 1, 5)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 5
    w = _writes_at(sim, PIO1_BASE + PIO_INSTR_MEM0 + 5 * 4)
    assert w and w[-1].value == 0xDEAD


def test_pio_sm_set_clkdiv_pack(fixture_elf):
    """CLKDIV = (int<<16) | (frac<<8)."""
    sim = _load(fixture_elf)
    _call(sim, "pio_sm_set_clkdiv", 0, 2, 0x1234, 0x56)
    addr = PIO0_BASE + PIO_SM0_CLKDIV + 2 * PIO_SM_STRIDE
    w = _writes_at(sim, addr)
    assert w and w[-1].value == ((0x1234 << 16) | (0x56 << 8))


def test_pio_sm_set_enabled_uses_atomic_alias(fixture_elf):
    """enable=1 hits the SET (+0x2000) alias; enable=0 hits CLR (+0x3000)."""
    sim = _load(fixture_elf)
    _call(sim, "pio_sm_set_enabled", 1, 3, 1)
    addr = PIO1_BASE + 0x2000 + PIO_CTRL
    w = _writes_at(sim, addr)
    assert w and w[-1].value == (1 << 3), f"PIO1 SET write: {w}"

    sim = _load(fixture_elf)
    _call(sim, "pio_sm_set_enabled", 1, 3, 0)
    addr = PIO1_BASE + 0x3000 + PIO_CTRL
    w = _writes_at(sim, addr)
    assert w and w[-1].value == (1 << 3)


def test_pio_sm_put_spins_then_stores(fixture_elf):
    """Spin on FSTAT.TX_FULL bit for sm, then store value to TXFn."""
    sim = _load(fixture_elf)
    polls = [0]

    def fstat_read(addr, size):
        polls[0] += 1
        # TX_FULL bits are FSTAT[3:0]. Hold bit 1 set for the first two reads,
        # then clear so the driver's loop exits.
        return (1 << 1) if polls[0] < 3 else 0

    sim.on_read(PIO0_BASE + PIO_FSTAT, 4, fstat_read)
    _call(sim, "pio_sm_put", 0, 1, 0xABCDEF01)
    w = _writes_at(sim, PIO0_BASE + PIO_TXF0 + 1 * 4)
    assert w and w[-1].value == 0xABCDEF01
    assert polls[0] >= 3, f"didn't spin on TX_FULL (polls={polls[0]})"


def test_pio_sm_exec_writes_to_sm_instr(fixture_elf):
    """pio_sm_exec(idx, sm, instr) stores `instr` at SM_INSTR (offset 0xD8 + sm*stride)."""
    sim = _load(fixture_elf)
    _call(sim, "pio_sm_exec", 2, 1, 0xABCD)
    addr = PIO2_BASE + PIO_SM0_INSTR + 1 * PIO_SM_STRIDE
    w = _writes_at(sim, addr)
    assert w and w[-1].value == 0xABCD


def test_pio_sm_set_set_pins_packs_pinctrl(fixture_elf):
    """SET_BASE @ [9:5] = pin; SET_COUNT @ [28:26] = count.  RMW preserves other fields."""
    sim = _load(fixture_elf)
    addr = PIO0_BASE + PIO_SM0_PINCTRL + 0 * PIO_SM_STRIDE
    sim.uc.mem_write(addr, struct.pack("<I", 0))
    _call(sim, "pio_sm_set_set_pins", 0, 0, 25, 1)
    w = _writes_at(sim, addr)
    assert w, f"no PINCTRL write: {sim.writes}"
    v = w[-1].value
    assert ((v >> 5) & 0x1F) == 25, f"SET_BASE wrong: {v:#x}"
    assert ((v >> 26) & 0x7) == 1, f"SET_COUNT wrong: {v:#x}"


def test_pio_sm_set_wrap_packs_execctrl(fixture_elf):
    """WRAP_BOTTOM @ bit 7..11; WRAP_TOP @ bit 12..16.  RMW preserves other bits."""
    sim = _load(fixture_elf)
    addr = PIO0_BASE + PIO_SM0_EXECCTRL + 0 * PIO_SM_STRIDE
    # Pre-seed EXECCTRL with some unrelated bits in the high half so we can
    # verify the RMW didn't smash them.
    sim.uc.mem_write(addr, struct.pack("<I", 0xC0000000))
    _call(sim, "pio_sm_set_wrap", 0, 0, 3, 7)
    w = _writes_at(sim, addr)
    assert w, "no EXECCTRL write"
    v = w[-1].value
    assert ((v >> 7) & 0x1F) == 3, f"WRAP_BOTTOM wrong: {v:#x}"
    assert ((v >> 12) & 0x1F) == 7, f"WRAP_TOP wrong: {v:#x}"
    assert (v & 0xC0000000) == 0xC0000000, f"high bits clobbered: {v:#x}"


def test_pio_gpio_init_dispatches_funcsel(fixture_elf):
    """pio_gpio_init(idx, pin) calls gpio_set_function(pin, 6+idx).

    Verify by checking the IO_BANK0 CTRL write that gpio_set_function emits.
    """
    sim = _load(fixture_elf)
    IO_BANK0_GPIO15_CTRL = 0x40028000 + 4 + 15 * 8
    _call(sim, "pio_gpio_init", 2, 15)
    w = _writes_at(sim, IO_BANK0_GPIO15_CTRL)
    assert w and w[-1].value == 8, (
        f"expected funcsel=8 (PIO2) at IO_BANK0[15] CTRL, got: {w}")
