# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""Parity test: `rpasm uf2 pack` (Go) must produce byte-identical UF2 output
to the legacy `tools/uf2.py` (Python) across a matrix of input sizes and
load addresses.

The Go tool is the long-term replacement; this test pins them together
until we delete `tools/uf2.py` for good.

Skips cleanly if `tools/bin/rpasm` hasn't been built yet (`make tools`).
"""

import filecmp
import os
import subprocess
import sys
import tempfile

import pytest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RPASM = os.path.join(REPO, "tools", "bin", "rpasm")
PY_UF2 = os.path.join(REPO, "tools", "uf2.py")


def _have_rpasm() -> bool:
    return os.path.isfile(RPASM) and os.access(RPASM, os.X_OK)


pytestmark = pytest.mark.skipif(
    not _have_rpasm(),
    reason="tools/bin/rpasm not built; run `make tools` first",
)


def _make_payload(size: int, seed: int) -> bytes:
    """Deterministic pseudo-random payload (seed-driven, no randomness)."""
    out = bytearray(size)
    s = seed & 0xFFFFFFFF
    for i in range(size):
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        out[i] = (s >> 16) & 0xFF
    return bytes(out)


# (size_bytes, base_addr)
CASES = [
    # SRAM family
    (1, 0x20000000),                 # smallest possible, pad to one 256-byte payload
    (256, 0x20000000),               # exact one block
    (257, 0x20000000),               # spills to a second block
    (4096, 0x20000000),              # 16 blocks
    (12345, 0x20000000),             # awkward size
    (0x10000, 0x20010000),           # 64 KiB at a non-base SRAM address
    # XIP flash family
    (1, 0x10000000),
    (256, 0x10000000),
    (512, 0x10000000),
    (4096, 0x10008000),              # the new SSBL slot base candidate
    (123456, 0x10000000),
    (0x100, 0x14FFFFFF & ~0xFF),     # near the top of the recognised XIP range
]


@pytest.mark.parametrize("size,base", CASES)
def test_parity(size: int, base: int) -> None:
    payload = _make_payload(size, seed=size ^ base)
    with tempfile.TemporaryDirectory() as td:
        bin_path = os.path.join(td, "in.bin")
        py_out = os.path.join(td, "out_py.uf2")
        go_out = os.path.join(td, "out_go.uf2")
        with open(bin_path, "wb") as f:
            f.write(payload)
        subprocess.run(
            [sys.executable, PY_UF2, bin_path, hex(base), py_out],
            check=True,
        )
        subprocess.run(
            [RPASM, "uf2", "pack", bin_path, hex(base), go_out],
            check=True,
        )
        assert filecmp.cmp(py_out, go_out, shallow=False), (
            f"Go UF2 differs from Python UF2 for size={size} base=0x{base:08X}"
        )


def test_go_rejects_bad_address() -> None:
    """The Go tool should fail (non-zero exit) for addresses outside RP2350
    flash/SRAM ranges, matching the Python tool's behaviour."""
    with tempfile.TemporaryDirectory() as td:
        bin_path = os.path.join(td, "in.bin")
        out_path = os.path.join(td, "out.uf2")
        with open(bin_path, "wb") as f:
            f.write(b"\x00" * 256)
        result = subprocess.run(
            [RPASM, "uf2", "pack", bin_path, "0x40000000", out_path],
            capture_output=True,
        )
        assert result.returncode != 0
        assert b"not in a known RP2350" in result.stderr
