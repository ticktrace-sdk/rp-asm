"""T1 tests for src/crc32.S - validates that the on-chip CRC32 routine
produces byte-identical output to Python's zlib.crc32 (and therefore to
Go's hash/crc32.ChecksumIEEE used by the host tooling) for a range of
inputs including empty, sub-word, exact-word, and large buffers.

If this test passes, mkmanifest-produced footers will validate against
the SSBL/TSBL on real silicon.
"""

import os
import struct
import subprocess
import sys
import zlib

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim, SRAM_BASE  # noqa: E402
from unicorn.arm_const import (  # noqa: E402
    UC_ARM_REG_R0, UC_ARM_REG_R1,
    UC_ARM_REG_LR, UC_ARM_REG_PC,
)


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    out = tmp_path_factory.mktemp("crc32_fixture")
    src = os.path.join(HERE, "fixtures", "crc32_api.S")
    obj = os.path.join(out, "crc32_api.o")
    elf = os.path.join(out, "crc32_api.elf")
    ld = os.path.join(out, "crc32_api.ld")
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


def _crc32_on_chip(elf: str, payload: bytes, scratch: int = SRAM_BASE + 0x1000) -> int:
    """Run crc32_compute on payload via the Unicorn harness; return r0."""
    sim = RP2350Sim()
    sim.load_elf(elf)
    park = sim.symbol("_park")
    func = sim.symbol("crc32_compute")

    sim.uc.mem_write(scratch, payload)
    sim.uc.reg_write(UC_ARM_REG_R0, scratch)
    sim.uc.reg_write(UC_ARM_REG_R1, len(payload))
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    # Generous max_steps: ~80 cycles/byte * largest test payload.
    sim.run_until_pc(park, max_steps=2_000_000)
    return sim.uc.reg_read(UC_ARM_REG_R0)


# A spread of sizes designed to catch boundary bugs: empty, 1 byte (the
# bit loop runs once), 4 bytes (one word, no tail), 7 (sub-word), 256
# (page-sized), and 12345 (awkward).
TEST_SIZES = [0, 1, 2, 3, 4, 7, 8, 15, 16, 32, 64, 256, 1024, 12345]


@pytest.mark.parametrize("size", TEST_SIZES)
def test_crc32_matches_zlib(fixture_elf, size: int) -> None:
    # Deterministic pseudo-random payload (LCG, no test-time randomness).
    payload = bytearray(size)
    s = (size * 1103515245 + 12345) & 0x7FFFFFFF
    for i in range(size):
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        payload[i] = (s >> 16) & 0xFF
    payload = bytes(payload)

    on_chip = _crc32_on_chip(fixture_elf, payload)
    expected = zlib.crc32(payload) & 0xFFFFFFFF
    assert on_chip == expected, (
        f"size={size}: on-chip 0x{on_chip:08X} != zlib 0x{expected:08X}"
    )


def test_crc32_known_vector(fixture_elf) -> None:
    """CRC-32/IEEE of 'The quick brown fox jumps over the lazy dog' is
    0x414FA339 (canonical test vector from RFC 1952 implementations)."""
    on_chip = _crc32_on_chip(
        fixture_elf, b"The quick brown fox jumps over the lazy dog")
    assert on_chip == 0x414FA339


def test_crc32_empty(fixture_elf) -> None:
    """Empty input should return 0 (init 0xFFFFFFFF xor-out 0xFFFFFFFF)."""
    assert _crc32_on_chip(fixture_elf, b"") == 0
