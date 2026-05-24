# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 smoke: RP2040 SRAM blinky image shape.

These tests don't depend on Unicorn yet (the M0+ harness is being added in
the next commit).  For now we assert the build-system contract:

  - chips/rp2040/src/main.S + the M2 driver set link into a working ELF.
  - The image's vector table has the right shape (SP at top of SRAM, Thumb-bit
    reset pointer into .text).
  - The packed UF2 advertises the RP2040 family ID (0xE48BFF56).
  - The ELF exposes every M2 public symbol so a future test can PC-inject
    against it.

If you add a new public function to chips/rp2040/src/*.S, add it to
EXPECTED_SYMBOLS so an accidental name change breaks the test.
"""

from __future__ import annotations

import os
import struct
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))

import sys as _sys
_sys.path.insert(0, os.path.join(REPO, "tools"))
from boot2_crc import crc32_mpeg2  # noqa: E402

BLINKY_ELF = os.path.join(REPO, "build", "rp2040", "blinky.elf")
BLINKY_UF2 = os.path.join(REPO, "build", "rp2040", "blinky.uf2")
BLINKY_BIN = os.path.join(REPO, "build", "rp2040", "blinky.bin")

FLASH_ELF = os.path.join(REPO, "build", "rp2040", "blinky_flash.elf")
FLASH_UF2 = os.path.join(REPO, "build", "rp2040", "blinky_flash.uf2")
FLASH_BIN = os.path.join(REPO, "build", "rp2040", "blinky_flash.bin")


def _need(path: str, make_target: str) -> None:
    if not os.path.exists(path):
        subprocess.check_call(
            ["make", "-C", REPO, make_target],
            stdout=subprocess.DEVNULL,
        )
    assert os.path.exists(path), f"{path} missing and `make {make_target}` did not produce it"


@pytest.fixture(scope="module")
def blinky_built():
    _need(BLINKY_UF2, "build/rp2040/blinky.uf2")
    _need(BLINKY_BIN, "build/rp2040/blinky.bin")
    return BLINKY_ELF, BLINKY_UF2, BLINKY_BIN


def test_blinky_elf_exists(blinky_built):
    elf, _, _ = blinky_built
    assert os.path.getsize(elf) > 0


def test_blinky_vectors_shape(blinky_built):
    """First 8 bytes of the binary image are the SP + Thumb reset pointer.

    For an SRAM-resident image at 0x20000000:
      vec[0] = _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4 = 0x20041FFC
      vec[1] = _reset | 1 (Thumb bit set, points into .text after _vectors)
    """
    _, _, bin_ = blinky_built
    with open(bin_, "rb") as f:
        head = f.read(8)
    sp, reset = struct.unpack("<II", head)
    assert sp == 0x20041FFC, f"SP = {sp:#x}, want 0x20041FFC"
    # Reset must land somewhere in .text past the 48-entry vector table
    # (last vector at offset 0xBC) and have the Thumb bit set.
    assert reset & 1, f"reset pointer {reset:#x} missing Thumb bit"
    assert 0x200000C0 <= (reset & ~1) < 0x20002000, (
        f"reset {reset:#x} outside expected .text band")


def test_blinky_uf2_family(blinky_built):
    """First UF2 block must carry the canonical RP2040 family ID."""
    _, uf2, _ = blinky_built
    with open(uf2, "rb") as f:
        block = f.read(512)
    assert len(block) == 512, "first UF2 block truncated"
    (m0, m1, flags, addr, payload_size, block_no, total_blocks, family) = \
        struct.unpack("<IIIIIIII", block[:32])
    assert m0 == 0x0A324655
    assert m1 == 0x9E5D5157
    assert flags & 0x00002000, "UF2 missing FAMILY_ID_PRESENT flag"
    assert addr == 0x20000000, f"first block target {addr:#x} != SRAM base"
    assert payload_size == 256
    assert family == 0xE48BFF56, f"family {family:#x} is not RP2040 (0xE48BFF56)"
    end_marker = struct.unpack("<I", block[-4:])[0]
    assert end_marker == 0x0AB16F30, f"UF2 end marker {end_marker:#x} invalid"


# Symbols blinky actually exercises via main.S; the rest can be gc'd when
# they have no caller in the linked image.
BLINKY_SYMBOLS = [
    "_vectors", "_reset", "_halt", "_ram_vectors", "main",
    "xosc_init",
    "pll_init", "pll_sys_125_mhz", "pll_usb_48_mhz",
    "clocks_init", "clocks_post_pll_uart_baud_fixup",
    "watchdog_disable", "tick_init",
    "gpio_led_init", "gpio_led_toggle",
    "uart0_init", "uart0_putc", "uart0_puts",
]


def test_blinky_exports_m2_symbols(blinky_built):
    """Symbols actually called by main.S must survive into the linked ELF."""
    elf, _, _ = blinky_built
    try:
        out = subprocess.check_output(
            ["arm-none-eabi-nm", "-g", elf], text=True)
    except FileNotFoundError:
        pytest.skip("arm-none-eabi-nm not on PATH")
    syms = {line.split()[-1] for line in out.splitlines() if line.strip()}
    missing = [s for s in BLINKY_SYMBOLS if s not in syms]
    assert not missing, f"missing M2 symbols in blinky.elf: {missing}"


# Full M2 driver surface, per .o file. The blinky link --gc-sections out's
# unused entry points so we check them at the object-file level instead,
# where every exported function survives.
DRIVER_SYMBOLS = {
    "gpio.o": [
        "gpio_set_function", "gpio_set_dir", "gpio_put", "gpio_get",
        "gpio_toggle", "gpio_init", "gpio_led_init", "gpio_led_toggle",
    ],
    "uart.o": [
        "uart0_init", "uart0_putc", "uart0_puts", "uart0_tx_wait_blocking",
    ],
    "pll.o": ["pll_init", "pll_sys_125_mhz", "pll_usb_48_mhz"],
    "clocks.o": ["clocks_init", "clocks_post_pll_uart_baud_fixup"],
    "watchdog.o": ["watchdog_disable", "tick_init"],
    "xosc.o": ["xosc_init"],
    "startup.o": ["_vectors", "_reset", "_halt", "_ram_vectors"],
}


@pytest.mark.parametrize("obj_name,expected", sorted(DRIVER_SYMBOLS.items()))
def test_driver_exports(obj_name, expected, blinky_built):
    obj_path = os.path.join(REPO, "build", "rp2040", obj_name)
    if not os.path.exists(obj_path):
        # build all driver objects via the umbrella target.
        subprocess.check_call(
            ["make", "-C", REPO, "rp2040-all"],
            stdout=subprocess.DEVNULL,
        )
    try:
        out = subprocess.check_output(
            ["arm-none-eabi-nm", "-g", obj_path], text=True)
    except FileNotFoundError:
        pytest.skip("arm-none-eabi-nm not on PATH")
    syms = {line.split()[-1] for line in out.splitlines() if line.strip()}
    missing = [s for s in expected if s not in syms]
    assert not missing, f"{obj_name}: missing exports {missing}"


# ---------------------------------------------------------------------------
# BOOT2 + flash image
# ---------------------------------------------------------------------------


def test_crc32_mpeg2_canonical_vector():
    """The CRC catalogue test vector for CRC-32/MPEG-2 is "123456789" ->
    0x0376E6E7.  Guards against accidental algorithm changes in boot2_crc.py.
    """
    assert crc32_mpeg2(b"123456789") == 0x0376E6E7


def test_crc32_mpeg2_init_state():
    """Empty input keeps the init register (0xFFFFFFFF)."""
    assert crc32_mpeg2(b"") == 0xFFFFFFFF


@pytest.fixture(scope="module")
def flash_built():
    _need(FLASH_UF2, "build/rp2040/blinky_flash.uf2")
    _need(FLASH_BIN, "build/rp2040/blinky_flash.bin")
    return FLASH_ELF, FLASH_UF2, FLASH_BIN


def test_flash_bin_boot2_size_and_crc(flash_built):
    """BOOT2 region is exactly 256 bytes at flash offset 0 and the trailing
    4 bytes are a valid CRC-32/MPEG-2 over the first 252 bytes."""
    _, _, bin_ = flash_built
    with open(bin_, "rb") as f:
        data = f.read()
    assert len(data) >= 256, f"flash bin is only {len(data)} bytes"
    boot2 = data[:256]
    crc_stored = struct.unpack("<I", boot2[252:256])[0]
    crc_computed = crc32_mpeg2(boot2[:252])
    assert crc_stored == crc_computed, (
        f"BOOT2 CRC mismatch: stored=0x{crc_stored:08X} "
        f"computed=0x{crc_computed:08X}")
    # The placeholder must have actually been overwritten - a zero CRC over
    # zero-padding plus zero code would be valid but means boot2_crc.py
    # didn't run.  The real BOOT2 has non-trivial code so the CRC is non-zero.
    assert crc_stored != 0, "BOOT2 CRC is zero - boot2_crc.py likely skipped"


def test_flash_bin_app_vectors_at_0x100(flash_built):
    """The first word after BOOT2 (flash offset 0x100 = 256) is the app's
    stack top, the second is its Thumb-bit reset handler."""
    _, _, bin_ = flash_built
    with open(bin_, "rb") as f:
        data = f.read()
    sp, reset = struct.unpack("<II", data[256:264])
    assert sp == 0x20041FFC, f"app SP at flash 0x100 = {sp:#x}, want 0x20041FFC"
    assert reset & 1, f"app reset {reset:#x} missing Thumb bit"
    # The reset handler lives in the app's .text band.
    assert 0x10000100 <= (reset & ~1) < 0x10100000, (
        f"app reset {reset:#x} not in expected flash .text band")


def test_flash_uf2_target_and_family(flash_built):
    """UF2 block 0 targets flash 0x10000000 and carries the RP2040 family."""
    _, uf2, _ = flash_built
    with open(uf2, "rb") as f:
        block0 = f.read(512)
    (_, _, _, addr, _, _, _, family) = struct.unpack("<IIIIIIII", block0[:32])
    assert addr == 0x10000000, f"flash UF2 block 0 targets 0x{addr:08X}"
    assert family == 0xE48BFF56, f"family 0x{family:08X} is not RP2040"


def test_flash_elf_section_layout(flash_built):
    """The linker must emit .boot2 as a 256-byte section at LMA 0x10000000
    and .text starting at LMA 0x10000100, with no overlap."""
    elf, _, _ = flash_built
    try:
        out = subprocess.check_output(
            ["arm-none-eabi-objdump", "-h", elf], text=True)
    except FileNotFoundError:
        pytest.skip("arm-none-eabi-objdump not on PATH")
    # Parse `Idx Name Size VMA LMA File off Algn` lines for .boot2 and .text.
    sections = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 6 and parts[1] in (".boot2", ".text"):
            sections[parts[1]] = {
                "size": int(parts[2], 16),
                "vma": int(parts[3], 16),
                "lma": int(parts[4], 16),
            }
    assert ".boot2" in sections, "no .boot2 section in flash ELF"
    assert ".text" in sections, "no .text section in flash ELF"
    assert sections[".boot2"]["lma"] == 0x10000000
    assert sections[".boot2"]["size"] == 0x100, (
        f".boot2 size {sections['.boot2']['size']:#x} != 0x100")
    assert sections[".text"]["lma"] == 0x10000100
    # boot2 end must equal text start (no gap, no overlap).
    boot2_end = sections[".boot2"]["lma"] + sections[".boot2"]["size"]
    assert boot2_end == sections[".text"]["lma"]
