# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 tests for src/trace.S - CoreSight DWT/ITM/TPIU/ETM driver.

All four blocks live in the PPB region (0xE0000000..0xE00FFFFF) which the
harness pre-maps, so no special mem_map setup required.
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

# ----- Addresses (match include/trace.inc) ---------------------------------
SCB_DEMCR = 0xE000EDFC
DEMCR_TRCENA = 1 << 24
CS_LAR_UNLOCK = 0xC5ACCE55

DWT_BASE = 0xE0001000
DWT_CTRL = DWT_BASE + 0x000
DWT_CYCCNT = DWT_BASE + 0x004
DWT_LAR = DWT_BASE + 0xFB0
DWT_CTRL_CYCCNTENA = 1 << 0

ITM_BASE = 0xE0000000
ITM_STIM0 = ITM_BASE + 0x000
ITM_TER = ITM_BASE + 0xE00
ITM_TPR = ITM_BASE + 0xE40
ITM_TCR = ITM_BASE + 0xE80
ITM_LAR = ITM_BASE + 0xFB0

TPIU_BASE = 0xE0040000
TPIU_ACPR = TPIU_BASE + 0x010
TPIU_SPPR = TPIU_BASE + 0x0F0
TPIU_FFCR = TPIU_BASE + 0x304
TPIU_CSPSR = TPIU_BASE + 0x004
TPIU_LAR = TPIU_BASE + 0xFB0

ETM_BASE = 0xE0041000
ETM_TRCPRGCTLR = ETM_BASE + 0x004
ETM_TRCSTATR = ETM_BASE + 0x00C
ETM_TRCCONFIGR = ETM_BASE + 0x010
ETM_TRCTRACEIDR = ETM_BASE + 0x040
ETM_TRCVICTLR = ETM_BASE + 0x080
ETM_TRCOSLAR = ETM_BASE + 0x300
ETM_TRCLAR = ETM_BASE + 0xFB0


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("trace_fixture")
    src = os.path.join(HERE, "fixtures", "trace_api.S")
    obj = os.path.join(out, "trace_api.o")
    elf = os.path.join(out, "trace_api.elf")
    ld = os.path.join(out, "trace_api.ld")
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


# ----- DWT ------------------------------------------------------------------


def test_dwt_init_sets_trcena_and_cyccntena(fixture_elf):
    sim = _load(fixture_elf)
    sim.poke32(SCB_DEMCR, 0)
    sim.poke32(DWT_CTRL, 0)
    _call(sim, "dwt_init")

    demcr = _writes_at(sim, SCB_DEMCR)
    assert demcr and (demcr[-1].value & DEMCR_TRCENA), \
        f"TRCENA not set in DEMCR: {demcr}"

    lar = _writes_at(sim, DWT_LAR)
    assert lar and lar[-1].value == CS_LAR_UNLOCK, \
        f"DWT_LAR not unlocked: {lar}"

    cyccnt = _writes_at(sim, DWT_CYCCNT)
    assert cyccnt and cyccnt[-1].value == 0, \
        f"CYCCNT not reset: {cyccnt}"

    ctrl = _writes_at(sim, DWT_CTRL)
    assert ctrl and (ctrl[-1].value & DWT_CTRL_CYCCNTENA), \
        f"CYCCNTENA not set: {ctrl}"


def test_dwt_cycles_read_returns_cyccnt(fixture_elf):
    sim = _load(fixture_elf)
    sim.poke32(DWT_CYCCNT, 0xDEADBEEF)
    _call(sim, "dwt_cycles_read")
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0xDEADBEEF


def test_dwt_cycles_since_subtracts_start(fixture_elf):
    sim = _load(fixture_elf)
    sim.poke32(DWT_CYCCNT, 1000)
    _call(sim, "dwt_cycles_since", 200)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 800


def test_dwt_cycles_since_handles_wrap(fixture_elf):
    """If CYCCNT wrapped past 2^32, the unsigned subtract still gives the
    right delta (works for any window < 2^32 cycles)."""
    sim = _load(fixture_elf)
    sim.poke32(DWT_CYCCNT, 100)
    _call(sim, "dwt_cycles_since", 0xFFFFFFF0)
    # 100 - 0xFFFFFFF0 mod 2^32 == 116
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 116


# ----- ITM ------------------------------------------------------------------


def test_itm_init_unlocks_and_enables(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "itm_init")

    lar = _writes_at(sim, ITM_LAR)
    assert lar and lar[-1].value == CS_LAR_UNLOCK

    ter = _writes_at(sim, ITM_TER)
    assert ter and ter[-1].value == 0xFFFFFFFF, "TER should enable all 32 ports"

    tpr = _writes_at(sim, ITM_TPR)
    assert tpr and tpr[-1].value == 0xFFFFFFFF

    tcr = _writes_at(sim, ITM_TCR)
    assert tcr
    v = tcr[-1].value
    # ITMENA | SYNCENA | TXENA | SWOENA + TraceID 1 at bit 16
    assert v & 0x1, "ITMENA not set"
    assert v & 0x4, "SYNCENA not set"
    assert v & 0x8, "TXENA not set"
    assert v & 0x10, "SWOENA not set"
    assert ((v >> 16) & 0x7F) == 1, f"TraceID wrong: {v:#x}"


def test_itm_putc_spins_then_stores_byte(fixture_elf):
    sim = _load(fixture_elf)
    polls = [0]

    def stim_read(addr, size):
        polls[0] += 1
        # Bit 0 = FIFOREADY.  Hold full for 2 polls, then ready.
        return 1 if polls[0] >= 3 else 0

    # Mock STIM port 3 (= ITM_STIM0 + 12)
    sim.on_read(ITM_STIM0 + 3 * 4, 4, stim_read)
    _call(sim, "itm_putc", 3, 0xAB)

    assert polls[0] >= 3, "didn't spin on FIFOREADY"
    stores = [w for w in sim.writes
              if w.addr == ITM_STIM0 + 3 * 4 and w.size == 1]
    assert stores and stores[-1].value == 0xAB, \
        f"didn't STRB byte to STIM[3]: {sim.writes}"


def test_itm_putw_does_a_word_store(fixture_elf):
    sim = _load(fixture_elf)
    sim.on_read(ITM_STIM0 + 5 * 4, 4, lambda a, s: 1)  # always ready
    _call(sim, "itm_putw", 5, 0xCAFE1234)
    stores = [w for w in sim.writes
              if w.addr == ITM_STIM0 + 5 * 4 and w.size == 4]
    assert stores and stores[-1].value == 0xCAFE1234


def test_itm_puts_walks_string_then_stops_on_null(fixture_elf):
    sim = _load(fixture_elf)
    MSG = SRAM_BASE + 0xD000
    sim.uc.mem_write(MSG, b"Hi\x00")
    sim.on_read(ITM_STIM0 + 0, 4, lambda a, s: 1)
    _call(sim, "itm_puts", 0, MSG)
    bytes_sent = [w.value for w in sim.writes
                  if w.addr == ITM_STIM0 + 0 and w.size == 1]
    assert bytes_sent == [ord('H'), ord('i')], f"got {bytes_sent}"


# ----- TPIU ----------------------------------------------------------------


def test_tpiu_init_swo_programs_acpr_and_sppr(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "tpiu_init_swo", 150_000_000, 2_000_000)
    lar = _writes_at(sim, TPIU_LAR)
    assert lar and lar[-1].value == CS_LAR_UNLOCK
    sppr = _writes_at(sim, TPIU_SPPR)
    assert sppr and sppr[-1].value == 2, "should select NRZ"
    acpr = _writes_at(sim, TPIU_ACPR)
    assert acpr and acpr[-1].value == 74, f"ACPR for 2 Mbps from 150 MHz = 74, got {acpr[-1].value}"


def test_tpiu_acpr_for_1mhz_at_150mhz(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "tpiu_init_swo", 150_000_000, 1_000_000)
    acpr = _writes_at(sim, TPIU_ACPR)
    assert acpr and acpr[-1].value == 149


# ----- ETM ------------------------------------------------------------------


def test_etm_init_simple_unlocks_configures_enables(fixture_elf):
    sim = _load(fixture_elf)

    # ETM_TRCSTATR returns IDLE bit then PMSTABLE bit so the two waits exit.
    reads = [0]

    def statr(addr, size):
        reads[0] += 1
        # First poll: IDLE = 1 (idle bit, satisfies the first spin).
        # Subsequent polls: PMSTABLE = 1 (satisfies the second spin).
        return 1 << 1 if reads[0] >= 2 else 1 << 0

    sim.on_read(ETM_TRCSTATR, 4, statr)
    _call(sim, "etm_init_simple")

    lar = _writes_at(sim, ETM_TRCLAR)
    assert lar and lar[-1].value == CS_LAR_UNLOCK
    oslar = _writes_at(sim, ETM_TRCOSLAR)
    assert oslar and oslar[-1].value == 0, "OS unlock writes 0"
    tid = _writes_at(sim, ETM_TRCTRACEIDR)
    assert tid and tid[-1].value == 2, "ETM trace ID should be 2"
    vic = _writes_at(sim, ETM_TRCVICTLR)
    assert vic and (vic[-1].value & (1 << 9)), "SSSTATUS should be 1 (trace from start)"
    prg = _writes_at(sim, ETM_TRCPRGCTLR)
    # Sequence: write 0 (disable for config), then write 1 (enable).
    assert len(prg) >= 2 and prg[-1].value == 1, f"PRGCTLR sequence: {prg}"


def test_etm_disable_clears_prgctlr_and_waits_idle(fixture_elf):
    sim = _load(fixture_elf)
    sim.on_read(ETM_TRCSTATR, 4, lambda a, s: 1)  # IDLE immediately
    _call(sim, "etm_disable")
    prg = _writes_at(sim, ETM_TRCPRGCTLR)
    assert prg and prg[-1].value == 0


# ----- trace_init composition ---------------------------------------------


def test_trace_init_composes_in_correct_order(fixture_elf):
    """DWT (sets TRCENA) must come before TPIU (which depends on TRCENA),
    which must come before ITM and ETM."""
    sim = _load(fixture_elf)
    sim.on_read(ETM_TRCSTATR, 4, lambda a, s: (1 << 0) | (1 << 1))  # IDLE + PMSTABLE
    _call(sim, "trace_init", 150_000_000, 2_000_000, max_steps=400_000)

    # Build an "order of first write to each block" map
    first_write = {}
    for w in sim.writes:
        # classify by block
        for name, base, top in [
            ("DEMCR", SCB_DEMCR, SCB_DEMCR + 4),
            ("DWT", DWT_BASE, DWT_BASE + 0x1000),
            ("ITM", ITM_BASE, ITM_BASE + 0x1000),
            ("TPIU", TPIU_BASE, TPIU_BASE + 0x1000),
            ("ETM", ETM_BASE, ETM_BASE + 0x1000),
        ]:
            if base <= w.addr < top and name not in first_write:
                first_write[name] = len(first_write)
                break

    assert first_write["DEMCR"] < first_write["TPIU"], \
        f"DEMCR.TRCENA must be set before TPIU.  Order: {first_write}"
    assert first_write["TPIU"] < first_write["ITM"], \
        f"TPIU must be configured before ITM.  Order: {first_write}"
    assert first_write["ITM"] < first_write["ETM"], \
        f"ITM must be initialised before ETM.  Order: {first_write}"
