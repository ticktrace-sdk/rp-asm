# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""Smoke test for the RP2350Sim harness.

Builds tests/unicorn/fixtures/smoke.S, loads it into Unicorn, and asserts
that the single STR is observed by the MMIO write hook with the expected
address and value.  If this test passes, the harness is wired correctly:
ELF/binary loading, vector unpacking, MMIO trapping, and program-counter
breakpoints all work.
"""

import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from harness import RP2350Sim, assemble  # noqa: E402


@pytest.fixture(scope="module")
def smoke_bin(tmp_path_factory):
    out = tmp_path_factory.mktemp("smoke")
    return assemble(os.path.join(HERE, "fixtures", "smoke.S"), str(out))


def test_smoke_single_write(smoke_bin):
    sim = RP2350Sim()
    sim.load_bin(smoke_bin)

    # _start is at SRAM_BASE + 8 (after the two-word vector table).  The
    # firmware is 8 bytes of ldr/ldr + a 4-byte STR + the self-loop branch.
    # The self-loop is at most 16 bytes past _start, so cap at PC == 0x20000020.
    sim.run_steps(20)

    # Exactly one write to SIO_GPIO_OUT
    assert len(sim.writes) == 1, f"expected 1 write, got {sim.writes}"
    w = sim.writes[0]
    assert w.is_write is True
    assert w.addr == 0xD0000010
    assert w.value == 0xCAFEBABE
    assert w.size == 4


def test_smoke_run_until_write(smoke_bin):
    """run_until_write() should stop at the first matching access."""
    sim = RP2350Sim()
    sim.load_bin(smoke_bin)
    ev = sim.run_until_write(0xD0000010)
    assert ev.value == 0xCAFEBABE


def test_smoke_read_hook():
    """Read hooks should patch in synthetic values."""
    sim = RP2350Sim()

    # Tiny inline program: ldr r0,=0x40070018 ; ldr r1,[r0] ; bkpt
    # We hand-assemble below; load_bin from bytes via a temp file.
    import struct, tempfile
    code = bytes()
    # vec0 SP, vec1 PC
    code += struct.pack("<II", 0x20080000, 0x20000009)  # _start at 0x20000008 + Thumb
    # ldr r0, [pc, #4]   -> 0x4801
    # ldr r1, [r0]       -> 0x6801
    # b .                -> 0xE7FE
    # .word 0x40070018
    code += struct.pack("<HHHHI", 0x4801, 0x6801, 0xE7FE, 0x0000, 0x40070018)

    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(code)
        path = f.name

    try:
        sim.load_bin(path)
        sim.on_read(0x40070018, 4, lambda a, s: 0xDEADBEEF)
        sim.run_steps(5)
        assert any(r.addr == 0x40070018 and r.value == 0xDEADBEEF
                   for r in sim.reads)
    finally:
        os.unlink(path)
