# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 trace assertions for src/i2c.S + the I2C examples (M4-F).

Pattern (mirrors tests/unicorn/test_pwm.py):
  1. Build tests/unicorn/fixtures/i2c_api.S into an ELF (loads src/gpio.S
     + src/i2c.S, parks at _park, keepalive table pins every public sym).
  2. Each test sets r0..r3 by hand, points PC at the function entry,
     LR at _park, runs until LR is hit, asserts on sim.writes.
  3. Examples are also built (via the Makefile) and we run the full demo
     ELFs through the simulator with the I2C mocks installed - confirms
     the demos wire the driver correctly without re-implementing it inline.
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
from mocks_i2c import (  # noqa: E402
    I2C0_BASE, I2C1_BASE, I2C_INSTANCE_STRIDE,
    IC_CON, IC_TAR, IC_SAR, IC_DATA_CMD,
    IC_SS_SCL_HCNT, IC_SS_SCL_LCNT,
    IC_FS_SCL_HCNT, IC_FS_SCL_LCNT,
    IC_INTR_MASK, IC_RX_TL, IC_TX_TL,
    IC_CLR_INTR, IC_CLR_TX_ABRT,
    IC_ENABLE, IC_STATUS, IC_TX_ABRT_SOURCE,
    IC_DMA_CR, IC_FS_SPKLEN, IC_SDA_HOLD,
    IC_DATA_CMD_CMD, IC_DATA_CMD_STOP,
    IC_STATUS_TFNF, IC_STATUS_TFE, IC_STATUS_RFNE,
    IC_STATUS_MST_ACTIVITY,
    IC_INTR_RX_FULL, IC_INTR_STOP_DET, IC_INTR_TX_ABRT,
    RESETS_I2C0, RESETS_I2C1,
    i2c_base,
    mock_i2c_resets_done,
    mock_i2c_status,
    mock_i2c_rxfifo,
    mock_i2c_busy_then_idle,
    mock_i2c_ready,
)
from unicorn.arm_const import (  # noqa: E402
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
    UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_SP,
)


RESETS_BASE = 0x40020000
ATOMIC_SET = 0x2000
ATOMIC_CLR = 0x3000


# ----------------------------------------------------------------- fixtures

@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    """Build tests/unicorn/fixtures/i2c_api.S into an ELF with full symbols."""
    out = tmp_path_factory.mktemp("i2c_fixture")
    src = os.path.join(HERE, "fixtures", "i2c_api.S")
    obj = os.path.join(out, "i2c_api.o")
    elf = os.path.join(out, "i2c_api.elf")
    ld = os.path.join(out, "i2c_api.ld")
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
    # cwd = REPO so `.include "src/i2c.S"` and `.include "src/gpio.S"` resolve.
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
    mock_i2c_resets_done(sim)
    return sim


def _call(sim, func_name, *args, max_steps=200_000):
    """Set r0..r{N-1} = args, point PC at func, LR at park sentinel.

    Run until execution reaches the park sentinel (function returned).
    """
    park = sim.symbol("_park")
    func = sim.symbol(func_name)
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
    for i, v in enumerate(args):
        sim.uc.reg_write(regs[i], v & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)   # Thumb bit
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=max_steps)


def _push_args(sim, *words):
    """Push a sequence of 32-bit words onto the stack.  Returns the new SP.

    Words are written so that words[0] ends up at [sp,#0] after push - i.e.
    we adjust SP by 4*len(words) and then store left-to-right.  Caller
    typically restores SP via add sp, sp, #N once the call has returned.
    """
    sp = sim.uc.reg_read(UC_ARM_REG_SP)
    sp -= 4 * len(words)
    sim.uc.reg_write(UC_ARM_REG_SP, sp)
    for i, w in enumerate(words):
        sim.uc.mem_write(sp + 4 * i, struct.pack("<I", w & 0xFFFFFFFF))
    return sp


# ============================================================================
# i2c_init
# ============================================================================


def test_init_clears_reset_bit_and_enables(fixture_elf):
    """i2c_init(0, 100000) must:
      - CLR RESETS bit 4 (i2c0)
      - write IC_ENABLE = 0 then IC_ENABLE = 1
      - write IC_CON = master FS
      - write IC_FS_SPKLEN
      - program SCL counts (SS_SCL_*) for 100 kHz
    """
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 0)
    _call(sim, "i2c_init", 0, 100000)

    base = i2c_base(0)
    # ---- RESETS clear includes bit 4 ----------------------------------
    clr = [w for w in sim.writes if w.addr == RESETS_BASE + ATOMIC_CLR]
    assert clr and clr[0].value & RESETS_I2C0, (
        f"first RESETS_CLR was {clr and clr[0].value:#x}, want bit 4 set")

    # ---- IC_ENABLE = 0, then = 1 ----------------------------------------
    en_writes = [w for w in sim.writes if w.addr == base + IC_ENABLE]
    assert len(en_writes) >= 2, f"only saw {len(en_writes)} IC_ENABLE writes"
    assert en_writes[0].value == 0, f"first IC_ENABLE write {en_writes[0].value:#x}, want 0"
    assert en_writes[-1].value == 1, f"last IC_ENABLE write {en_writes[-1].value:#x}, want 1"

    # ---- IC_CON master FS bits set --------------------------------------
    con_writes = [w for w in sim.writes if w.addr == base + IC_CON]
    assert con_writes, "no IC_CON write"
    con = con_writes[0].value
    assert con & 1, f"IC_CON.MASTER_MODE not set ({con:#x})"
    assert (con >> 1) & 3 == 2, f"IC_CON.SPEED not FS ({con:#x})"
    assert con & (1 << 5), f"IC_CON.RESTART_EN not set ({con:#x})"
    assert con & (1 << 6), f"IC_CON.SLAVE_DISABLE not set ({con:#x})"

    # ---- IC_FS_SPKLEN written -------------------------------------------
    spklen = [w for w in sim.writes if w.addr == base + IC_FS_SPKLEN]
    assert spklen and spklen[0].value > 0

    # ---- SS_SCL_* programmed for 100 kHz --------------------------------
    hcnt = [w for w in sim.writes if w.addr == base + IC_SS_SCL_HCNT]
    lcnt = [w for w in sim.writes if w.addr == base + IC_SS_SCL_LCNT]
    assert hcnt and lcnt, "SS HCNT/LCNT not programmed"
    # Driver formula: period = clk_peri / freq = 1500 ticks at 100 kHz.
    # HCNT = period*4/10 - 8 = 592; LCNT = period*6/10 - 1 = 899.
    # Allow some slack for future formula tweaks but require both > 0.
    assert hcnt[0].value > 100, f"SS HCNT = {hcnt[0].value} (want > 100)"
    assert lcnt[0].value > 100, f"SS LCNT = {lcnt[0].value} (want > 100)"
    # And HCNT + LCNT should be close to clk_peri/freq (= 1500 at 150 MHz/100 kHz).
    assert 1300 <= hcnt[0].value + lcnt[0].value <= 1700, (
        f"HCNT + LCNT = {hcnt[0].value + lcnt[0].value} (want ~1500)")


def test_init_idx1_uses_i2c1_base(fixture_elf):
    """i2c_init(1, 100000) must address I2C1_BASE registers, and CLR
    RESETS bit 5 (not bit 4)."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 1)
    _call(sim, "i2c_init", 1, 100000)

    clr = [w for w in sim.writes if w.addr == RESETS_BASE + ATOMIC_CLR]
    assert clr and clr[0].value & RESETS_I2C1, (
        f"RESETS_CLR was {clr and clr[0].value:#x}, want bit 5 set")

    base = i2c_base(1)
    en_writes = [w for w in sim.writes if w.addr == base + IC_ENABLE]
    assert en_writes, "no IC_ENABLE writes at I2C1_BASE"


# ============================================================================
# i2c_set_baudrate
# ============================================================================


def test_set_baudrate_400k_uses_fs_registers(fixture_elf):
    """At 400 kHz the driver must program IC_FS_SCL_HCNT/LCNT, not the SS pair."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 0)
    _call(sim, "i2c_set_baudrate", 0, 400000)

    base = i2c_base(0)
    fs_h = [w for w in sim.writes if w.addr == base + IC_FS_SCL_HCNT]
    fs_l = [w for w in sim.writes if w.addr == base + IC_FS_SCL_LCNT]
    assert fs_h, "FS HCNT not programmed at 400 kHz"
    assert fs_l, "FS LCNT not programmed at 400 kHz"
    # Period = 375 ticks at 150 MHz/400 kHz; HCNT~142, LCNT~224.
    # HCNT + LCNT should be close to clk_peri/freq (375 ticks).
    assert 300 <= fs_h[0].value + fs_l[0].value <= 450, (
        f"HCNT + LCNT = {fs_h[0].value + fs_l[0].value} @ 400 kHz, want ~375")

    # SS registers must NOT be touched in the 400 kHz path
    ss_h = [w for w in sim.writes if w.addr == base + IC_SS_SCL_HCNT]
    assert not ss_h, "SS HCNT should not be programmed at 400 kHz"


def test_set_baudrate_100k_uses_ss_registers(fixture_elf):
    """At 100 kHz the driver routes through IC_SS_SCL_HCNT/LCNT."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 0)
    _call(sim, "i2c_set_baudrate", 0, 100000)

    base = i2c_base(0)
    ss_h = [w for w in sim.writes if w.addr == base + IC_SS_SCL_HCNT]
    ss_l = [w for w in sim.writes if w.addr == base + IC_SS_SCL_LCNT]
    assert ss_h and ss_l, "SS counts not programmed at 100 kHz"
    fs_h = [w for w in sim.writes if w.addr == base + IC_FS_SCL_HCNT]
    assert not fs_h, "FS HCNT should not be programmed at 100 kHz"


def test_set_baudrate_1m_uses_fs_registers_and_short_hold(fixture_elf):
    """At 1 MHz the driver still uses FS registers (Fast+) and switches
    to the smaller SDA hold time so tHD;DAT stays within spec."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 0)
    _call(sim, "i2c_set_baudrate", 0, 1000000)

    base = i2c_base(0)
    fs_h = [w for w in sim.writes if w.addr == base + IC_FS_SCL_HCNT]
    fs_l = [w for w in sim.writes if w.addr == base + IC_FS_SCL_LCNT]
    # Period = 150 ticks at 150 MHz/1 MHz.
    assert fs_h and fs_l, "FS counts missing at 1 MHz"
    assert 120 <= fs_h[0].value + fs_l[0].value <= 180, (
        f"HCNT + LCNT = {fs_h[0].value + fs_l[0].value} @ 1 MHz, want ~150")
    sda_hold = [w for w in sim.writes if w.addr == base + IC_SDA_HOLD]
    # Last write determines the held value; should be the short (4) variant.
    assert sda_hold and sda_hold[-1].value <= 6, (
        f"SDA_HOLD @ 1 MHz = {sda_hold[-1].value}, want <= 6")


# ============================================================================
# i2c_write_blocking
# ============================================================================


def test_write_blocking_sets_tar_and_streams_bytes_with_stop(fixture_elf):
    """A 4-byte write must set IC_TAR, push 4 bytes via IC_DATA_CMD, last
    one carrying the STOP bit (bit 9)."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 0)
    # Pre-load a source buffer in SRAM
    src = 0x20002000
    sim.uc.mem_write(src, bytes([0x11, 0x22, 0x33, 0x44]))

    # Push nostop = 0 onto stack
    _push_args(sim, 0)
    _call(sim, "i2c_write_blocking", 0, 0x55, src, 4)
    sim.uc.reg_write(UC_ARM_REG_SP,
                     sim.uc.reg_read(UC_ARM_REG_SP) + 4)

    base = i2c_base(0)
    tar = [w for w in sim.writes if w.addr == base + IC_TAR]
    assert tar and tar[0].value == 0x55, f"IC_TAR = {tar and tar[0].value:#x}"

    data_writes = [w for w in sim.writes if w.addr == base + IC_DATA_CMD]
    assert len(data_writes) == 4, f"saw {len(data_writes)} data writes, want 4"

    # First three must NOT carry STOP, last one MUST carry STOP.
    for i, w in enumerate(data_writes[:-1]):
        assert not (w.value & IC_DATA_CMD_STOP), (
            f"byte {i} unexpectedly had STOP set ({w.value:#x})")
    assert data_writes[-1].value & IC_DATA_CMD_STOP, (
        f"last byte missing STOP ({data_writes[-1].value:#x})")
    # Data bytes match the source
    assert [w.value & 0xFF for w in data_writes] == [0x11, 0x22, 0x33, 0x44]


def test_write_blocking_nostop_keeps_bus(fixture_elf):
    """nostop=1 must NOT set the STOP bit on the last byte."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 0)
    src = 0x20002100
    sim.uc.mem_write(src, bytes([0xAA, 0xBB]))

    _push_args(sim, 1)             # nostop = 1
    _call(sim, "i2c_write_blocking", 0, 0x42, src, 2)
    sim.uc.reg_write(UC_ARM_REG_SP,
                     sim.uc.reg_read(UC_ARM_REG_SP) + 4)

    base = i2c_base(0)
    data_writes = [w for w in sim.writes if w.addr == base + IC_DATA_CMD]
    assert len(data_writes) == 2
    for i, w in enumerate(data_writes):
        assert not (w.value & IC_DATA_CMD_STOP), (
            f"nostop=1 but byte {i} carried STOP ({w.value:#x})")


def test_write_blocking_returns_byte_count(fixture_elf):
    """Successful write returns the number of bytes pushed in r0."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_ready(sim, 0)
    src = 0x20002200
    sim.uc.mem_write(src, bytes([0x11, 0x22, 0x33]))

    _push_args(sim, 0)
    _call(sim, "i2c_write_blocking", 0, 0x12, src, 3)
    sim.uc.reg_write(UC_ARM_REG_SP,
                     sim.uc.reg_read(UC_ARM_REG_SP) + 4)

    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    assert r0 == 3, f"expected 3 bytes written, got {r0}"


# ============================================================================
# i2c_read_blocking
# ============================================================================


def test_read_blocking_pushes_n_reads_with_stop_on_last(fixture_elf):
    """A 3-byte read pushes 3 IC_DATA_CMD writes, each with CMD=1 (read);
    the last one carries STOP."""
    sim = _load_fixture(fixture_elf)
    # RX FIFO has 3 bytes pre-loaded
    mock_i2c_rxfifo(sim, 0, [0xDE, 0xAD, 0xBE])

    dst = 0x20003000
    _push_args(sim, 0)
    _call(sim, "i2c_read_blocking", 0, 0x42, dst, 3)
    sim.uc.reg_write(UC_ARM_REG_SP,
                     sim.uc.reg_read(UC_ARM_REG_SP) + 4)

    base = i2c_base(0)
    cmd_writes = [w for w in sim.writes if w.addr == base + IC_DATA_CMD]
    # We expect exactly 3 read commands, all with CMD bit set.
    assert len(cmd_writes) == 3, f"saw {len(cmd_writes)} cmd writes"
    for i, w in enumerate(cmd_writes):
        assert w.value & IC_DATA_CMD_CMD, (
            f"cmd {i} missing CMD bit ({w.value:#x})")
    # Last one carries STOP
    assert cmd_writes[-1].value & IC_DATA_CMD_STOP, (
        f"last read cmd missing STOP ({cmd_writes[-1].value:#x})")

    # And dst now holds the popped bytes
    rx = bytes(sim.uc.mem_read(dst, 3))
    assert rx == bytes([0xDE, 0xAD, 0xBE]), f"got {rx.hex()}"

    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    assert r0 == 3, f"expected 3 bytes read, got {r0}"


def test_read_blocking_nostop(fixture_elf):
    """nostop=1 must NOT set STOP on the last read cmd."""
    sim = _load_fixture(fixture_elf)
    mock_i2c_rxfifo(sim, 0, [0x01, 0x02])

    dst = 0x20003100
    _push_args(sim, 1)
    _call(sim, "i2c_read_blocking", 0, 0x42, dst, 2)
    sim.uc.reg_write(UC_ARM_REG_SP,
                     sim.uc.reg_read(UC_ARM_REG_SP) + 4)

    base = i2c_base(0)
    cmd_writes = [w for w in sim.writes if w.addr == base + IC_DATA_CMD]
    for i, w in enumerate(cmd_writes):
        assert not (w.value & IC_DATA_CMD_STOP), (
            f"nostop=1 but cmd {i} carried STOP ({w.value:#x})")


# ============================================================================
# i2c_set_irqs_enabled
# ============================================================================


def test_set_irqs_enabled_writes_intr_mask(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mask = IC_INTR_RX_FULL | IC_INTR_STOP_DET
    _call(sim, "i2c_set_irqs_enabled", 0, mask)

    base = i2c_base(0)
    ws = [w for w in sim.writes if w.addr == base + IC_INTR_MASK]
    # i2c_init pre-writes IC_INTR_MASK = 0; THIS test calls only
    # i2c_set_irqs_enabled, so we should see exactly one write here.
    assert ws, "no IC_INTR_MASK write"
    assert ws[-1].value == mask, f"IC_INTR_MASK = {ws[-1].value:#x}, want {mask:#x}"


def test_set_irqs_enabled_idx1(fixture_elf):
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_set_irqs_enabled", 1, IC_INTR_TX_ABRT)

    base = i2c_base(1)
    ws = [w for w in sim.writes if w.addr == base + IC_INTR_MASK]
    assert ws and ws[-1].value == IC_INTR_TX_ABRT


# ============================================================================
# i2c_clear_irq
# ============================================================================


def test_clear_irq_combined(fixture_elf):
    """i2c_clear_irq(0, 0) must read IC_CLR_INTR (offset 0x40)."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_clear_irq", 0, 0)

    base = i2c_base(0)
    rs = [r for r in sim.reads if r.addr == base + IC_CLR_INTR]
    assert rs, "no IC_CLR_INTR read"


def test_clear_irq_specific_tx_abrt(fixture_elf):
    """i2c_clear_irq(0, IC_INTR_TX_ABRT) must read IC_CLR_TX_ABRT (offset 0x54)."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_clear_irq", 0, IC_INTR_TX_ABRT)

    base = i2c_base(0)
    rs = [r for r in sim.reads if r.addr == base + IC_CLR_TX_ABRT]
    assert rs, "no IC_CLR_TX_ABRT read"


# ============================================================================
# i2c_set_dma_enabled
# ============================================================================


def test_set_dma_enabled_both(fixture_elf):
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_set_dma_enabled", 0, 1, 1)
    base = i2c_base(0)
    ws = [w for w in sim.writes if w.addr == base + IC_DMA_CR]
    assert ws and ws[-1].value == 0b11, f"IC_DMA_CR = {ws[-1].value:#x}, want 0b11"


def test_set_dma_enabled_tx_only(fixture_elf):
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_set_dma_enabled", 0, 1, 0)
    base = i2c_base(0)
    ws = [w for w in sim.writes if w.addr == base + IC_DMA_CR]
    assert ws and ws[-1].value == 0b10, f"IC_DMA_CR = {ws[-1].value:#x}, want 0b10"


def test_set_dma_enabled_off(fixture_elf):
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_set_dma_enabled", 0, 0, 0)
    base = i2c_base(0)
    ws = [w for w in sim.writes if w.addr == base + IC_DMA_CR]
    assert ws and ws[-1].value == 0


# ============================================================================
# i2c_set_slave_mode
# ============================================================================


def test_set_slave_mode_writes_sar_and_clears_master(fixture_elf):
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_set_slave_mode", 0, 0x42)

    base = i2c_base(0)
    sar = [w for w in sim.writes if w.addr == base + IC_SAR]
    assert sar and sar[0].value == 0x42

    # IC_CON write must NOT have MASTER_MODE bit set in the slave path.
    con = [w for w in sim.writes if w.addr == base + IC_CON]
    assert con, "no IC_CON write in slave-mode path"
    for w in con:
        # Could see multiple CON writes; the last is the slave-mode value.
        pass
    assert not (con[-1].value & 1), (
        f"IC_CON.MASTER_MODE still set in slave-mode path ({con[-1].value:#x})")


# ============================================================================
# i2c_get_status
# ============================================================================


def test_get_status_returns_register_value(fixture_elf):
    sim = _load_fixture(fixture_elf)
    expected = IC_STATUS_TFNF | IC_STATUS_TFE
    sim.poke32(i2c_base(0) + IC_STATUS, expected)
    _call(sim, "i2c_get_status", 0)

    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    assert r0 == expected, f"r0 = {r0:#x}, want {expected:#x}"


# ============================================================================
# i2c_set_pins
# ============================================================================


def test_set_pins_calls_gpio_set_function_for_both(fixture_elf):
    """i2c_set_pins(0, 4, 5) must:
      - write IO_BANK0 CTRL for pin 4 = GPIO_FUNC_I2C (3)
      - write IO_BANK0 CTRL for pin 5 = GPIO_FUNC_I2C (3)
      - SET PADS_BANK0 PUE bits for both pins (gpio_pull_up).
    """
    IO_BANK0 = 0x40028000
    PADS_BANK0 = 0x40038000
    sim = _load_fixture(fixture_elf)
    _call(sim, "i2c_set_pins", 0, 4, 5)

    # IO_BANK0 CTRL[4] = base + 4 + 4*8 = base + 0x24
    ctrl_p4 = [w for w in sim.writes if w.addr == IO_BANK0 + 4 + 4 * 8]
    ctrl_p5 = [w for w in sim.writes if w.addr == IO_BANK0 + 4 + 5 * 8]
    assert ctrl_p4 and ctrl_p4[0].value == 3, (
        f"GP4 funcsel = {ctrl_p4 and ctrl_p4[0].value}, want 3 (I2C)")
    assert ctrl_p5 and ctrl_p5[0].value == 3, (
        f"GP5 funcsel = {ctrl_p5 and ctrl_p5[0].value}, want 3 (I2C)")

    # gpio_pull_up writes PADS via the SET alias
    set_p4 = [w for w in sim.writes
              if w.addr == PADS_BANK0 + ATOMIC_SET + 4 + 4 * 4
              and w.value & (1 << 3)]   # PUE bit
    set_p5 = [w for w in sim.writes
              if w.addr == PADS_BANK0 + ATOMIC_SET + 4 + 5 * 4
              and w.value & (1 << 3)]
    assert set_p4, "GP4 PUE bit never set"
    assert set_p5, "GP5 PUE bit never set"


# ============================================================================
# Spin-loop exit confirmation
# ============================================================================


def test_write_blocking_polls_status_then_exits(fixture_elf):
    """With mock_i2c_busy_then_idle the MST_ACTIVITY spin should poll the
    requested number of times and then exit cleanly."""
    sim = _load_fixture(fixture_elf)
    state = mock_i2c_busy_then_idle(sim, 0, n_polls=3)
    src = 0x20002400
    sim.uc.mem_write(src, bytes([0x42]))

    _push_args(sim, 0)
    _call(sim, "i2c_write_blocking", 0, 0x12, src, 1)
    sim.uc.reg_write(UC_ARM_REG_SP,
                     sim.uc.reg_read(UC_ARM_REG_SP) + 4)

    # MST_ACTIVITY spin must have observed the mock at least n_polls + 1 times
    # (the +1 is the final read where the bit is clear).
    assert state["reads"] >= 4, (
        f"only saw {state['reads']} IC_STATUS reads, want >= 4")


# ============================================================================
# End-to-end: examples build and exercise the driver
# ============================================================================


SCAN_ELF = os.path.join(REPO, "build", "i2c_scan_demo.elf")
EEPROM_ELF = os.path.join(REPO, "build", "i2c_eeprom_demo.elf")
LOOP_ELF = os.path.join(REPO, "build", "i2c_master_slave_loopback_demo.elf")


def _ensure_demo(elf_path: str, uf2_path: str):
    if not os.path.exists(elf_path):
        subprocess.check_call(
            ["make", "-C", REPO, uf2_path],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(elf_path):
        pytest.skip(f"{elf_path} missing and `make` did not produce it")


def test_scan_demo_initialises_i2c0_and_emits_banner():
    _ensure_demo(SCAN_ELF, "build/i2c_scan_demo.uf2")

    sim = RP2350Sim()
    sim.load_elf(SCAN_ELF)
    sim.mock_resets_done()
    mock_i2c_resets_done(sim)
    # Make every probe NACK by leaving TX_ABRT_SOURCE non-zero
    base = i2c_base(0)

    state = {"reads": 0}

    def status_cb(addr: int, size: int):
        offset = addr - base
        if offset == IC_STATUS:
            return IC_STATUS_TFNF | IC_STATUS_TFE
        if offset == IC_TX_ABRT_SOURCE:
            # First call after each transaction returns non-zero (NACK).
            return 1
        return None

    sim.on_read(base, 0x4000, status_cb)
    tx = sim.mock_uart0_tx()

    # Run for plenty of cycles - the scan over 112 addresses takes a while.
    sim.run_steps(2_000_000)

    text = bytes(tx).decode("ascii", errors="replace")
    assert "I2C bus scan" in text, f"banner missing from UART output: {text!r}"


def test_eeprom_demo_drives_address_0x50_with_restart_pattern():
    _ensure_demo(EEPROM_ELF, "build/i2c_eeprom_demo.uf2")

    sim = RP2350Sim()
    sim.load_elf(EEPROM_ELF)
    sim.mock_resets_done()
    mock_i2c_resets_done(sim)

    base = i2c_base(0)

    # Build a function that returns a sequence of fake EEPROM bytes.
    rx_queue = [0xA5, 0xB6, 0xC7, 0xD8]

    def cb(addr: int, size: int):
        offset = addr - base
        if offset == IC_STATUS:
            s = IC_STATUS_TFNF | IC_STATUS_TFE
            if rx_queue:
                s |= IC_STATUS_RFNE
            return s
        if offset == IC_DATA_CMD and rx_queue:
            return rx_queue.pop(0)
        if offset == IC_TX_ABRT_SOURCE:
            return 0
        return None

    sim.on_read(base, 0x4000, cb)
    tx = sim.mock_uart0_tx()
    sim.run_steps(2_000_000)

    text = bytes(tx).decode("ascii", errors="replace")
    assert "EEPROM" in text, f"no banner: {text!r}"

    # IC_TAR must have been set to 0x50 at some point.
    tar_writes = [w for w in sim.writes if w.addr == base + IC_TAR]
    assert tar_writes and any(w.value == 0x50 for w in tar_writes), (
        f"IC_TAR never set to 0x50; saw {[hex(w.value) for w in tar_writes]}")


def test_loopback_demo_initialises_both_instances():
    _ensure_demo(LOOP_ELF, "build/i2c_master_slave_loopback_demo.uf2")

    sim = RP2350Sim()
    sim.load_elf(LOOP_ELF)
    sim.mock_resets_done()
    mock_i2c_resets_done(sim)

    # Both instances stay TX-ready forever
    mock_i2c_ready(sim, 0)
    mock_i2c_ready(sim, 1)
    # Slave's IC_TX_ABRT_SOURCE must read 0 (no abort).
    # Already covered by mock_i2c_ready returning None for non-IC_STATUS reads,
    # which means Unicorn falls back to the zero-initialised mapped memory.

    tx = sim.mock_uart0_tx()
    sim.run_steps(1_500_000)

    text = bytes(tx).decode("ascii", errors="replace")
    assert "loopback" in text.lower(), f"no banner: {text!r}"

    # Both bases must have seen IC_ENABLE writes (init was called twice).
    en0 = [w for w in sim.writes if w.addr == I2C0_BASE + IC_ENABLE]
    en1 = [w for w in sim.writes if w.addr == I2C1_BASE + IC_ENABLE]
    assert en0, "I2C0 IC_ENABLE never written"
    assert en1, "I2C1 IC_ENABLE never written"
