# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T2: pytest wrapper around tests/qemu/run.sh.

Discovers every .S in tests/qemu/cases/, runs it under qemu-system-arm,
and asserts the expected token appears in stdout AND that QEMU exited 0.

Each fixture .S declares its expected stdout token via a magic comment
on the second line:

    @ EXPECT: <substring>

If the marker is absent, the runner only checks that QEMU exited 0.
"""

import os
import shutil
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_SH = os.path.join(HERE, "run.sh")
CASES_DIR = os.path.join(HERE, "cases")


def _expect_token(src_path: str) -> str:
    """Read EXPECT marker from a fixture (defaults to empty -> exit-only)."""
    with open(src_path) as f:
        for _ in range(5):  # only look in the first 5 lines
            line = f.readline()
            if "EXPECT:" in line:
                return line.split("EXPECT:", 1)[1].strip()
    return ""


def _cases():
    if not os.path.isdir(CASES_DIR):
        return []
    return sorted(
        os.path.join(CASES_DIR, n)
        for n in os.listdir(CASES_DIR)
        if n.endswith(".S")
    )


@pytest.fixture(scope="session", autouse=True)
def _qemu_available():
    if shutil.which("qemu-system-arm") is None:
        pytest.skip("qemu-system-arm not installed")


def test_sanity_runs():
    """The bedrock test: tests/qemu/sanity.S must always pass."""
    rc = subprocess.call([RUN_SH], cwd=HERE)
    assert rc == 0, "sanity.S failed under QEMU"


@pytest.mark.parametrize("case", _cases(), ids=lambda p: os.path.basename(p))
def test_case(case: str):
    expect = _expect_token(case)
    rc = subprocess.call([RUN_SH, case, expect], cwd=HERE)
    assert rc == 0, f"{case} failed under QEMU (expected token: {expect!r})"
