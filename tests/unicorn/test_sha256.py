"""T1 tests for the M5-L SHA-256 hardware driver.

Mirrors test_uart.py's fixture-ELF + PC-inject pattern.
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

SHA256_BASE = 0x400F8000
SHA256_CSR = SHA256_BASE + 0x00
SHA256_WDATA = SHA256_BASE + 0x04
SHA256_SUM0 = SHA256_BASE + 0x08
RESETS_BASE = 0x40020000
RESETS_RESET_CLR = RESETS_BASE + 0x3000

CSR_START = 1 << 0
CSR_WDATA_READY = 1 << 1
CSR_SUM_VLD = 1 << 2
CSR_BSWAP = 1 << 12
CSR_DMA_SIZE_WORD = 2 << 8


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("sha256_fixture")
    src = os.path.join(HERE, "fixtures", "sha256_api.S")
    obj = os.path.join(out, "sha256_api.o")
    elf = os.path.join(out, "sha256_api.elf")
    ld = os.path.join(out, "sha256_api.ld")
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


def test_sha256_init_resets_then_csr(fixture_elf):
    sim = _load(fixture_elf)
    _call(sim, "sha256_init")
    rs = _writes_at(sim, RESETS_RESET_CLR)
    assert rs and rs[0].value == (1 << 17), (
        f"expected RESETS CLR with bit 17 (sha256); got {rs}")
    csr = _writes_at(sim, SHA256_CSR)
    assert csr and csr[-1].value == (CSR_DMA_SIZE_WORD | CSR_BSWAP), (
        f"CSR final value: {csr}")


def test_sha256_write_word_spin_then_store(fixture_elf):
    sim = _load(fixture_elf)
    polls = [0]
    def csr_read(addr, size):
        polls[0] += 1
        return CSR_WDATA_READY if polls[0] >= 3 else 0
    sim.on_read(SHA256_CSR, 4, csr_read)
    _call(sim, "sha256_write_word", 0xCAFEBABE)
    assert polls[0] >= 3, f"firmware didn't spin on WDATA_READY (polls={polls[0]})"
    wd = _writes_at(sim, SHA256_WDATA)
    assert len(wd) == 1 and wd[0].value == 0xCAFEBABE


def test_sha256_get_digest_polls_sumvld_then_reads_8(fixture_elf):
    sim = _load(fixture_elf)
    DST = SRAM_BASE + 0xE000
    polls = [0]
    def csr_read(addr, size):
        polls[0] += 1
        return CSR_SUM_VLD if polls[0] >= 2 else 0
    sim.on_read(SHA256_CSR, 4, csr_read)
    expected = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
                0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    for i, v in enumerate(expected):
        sim.on_read(SHA256_SUM0 + i * 4, 4, (lambda val: lambda a, s: val)(v))
    _call(sim, "sha256_get_digest", DST)
    out = list(struct.unpack("<8I", sim.uc.mem_read(DST, 32)))
    assert out == expected


def test_sha256_compute_abc_block(fixture_elf):
    """For msg='abc', expect one padded block:
        'abc' + 0x80 + 52 zeros + BE-64bit length (24 bits).
    With CSR.BSWAP=1 the engine reads each LE word and byte-swaps internally,
    so we just check that the LE word stream matches the LE word view of the
    padded block."""
    sim = _load(fixture_elf)
    sim.on_read(SHA256_CSR, 4, lambda a, s: CSR_WDATA_READY | CSR_SUM_VLD)
    for i in range(8):
        sim.on_read(SHA256_SUM0 + i * 4, 4, lambda a, s: 0)

    MSG = SRAM_BASE + 0xD000
    DST = SRAM_BASE + 0xE000
    sim.uc.mem_write(MSG, b"abc")
    _call(sim, "sha256_compute", MSG, 3, DST)

    block = b"abc" + b"\x80" + b"\x00" * 52 + b"\x00\x00\x00\x00\x00\x00\x00\x18"
    assert len(block) == 64
    expected = list(struct.unpack("<16I", block))
    wd = [w.value & 0xFFFFFFFF for w in _writes_at(sim, SHA256_WDATA)]
    assert wd == expected, (
        f"WDATA sequence mismatch:\n  got:    {[hex(x) for x in wd]}\n"
        f"  wanted: {[hex(x) for x in expected]}"
    )
