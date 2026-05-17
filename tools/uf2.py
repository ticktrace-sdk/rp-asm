#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""uf2.py - tiny .bin -> .uf2 packer for RP2350.

Format reference: https://github.com/microsoft/uf2

Each 512-byte block:
    u32 magic_start0     0x0A324655
    u32 magic_start1     0x9E5D5157
    u32 flags            0x00002000  (FAMILY_ID_PRESENT)
    u32 target_addr      absolute load address for this block
    u32 payload_size     bytes of actual data in `data` (we use 256)
    u32 block_no         0-indexed
    u32 num_blocks
    u32 file_size_or_family_id
    u8  data[476]        zero-padded payload
    u32 magic_end        0x0AB16F30

Family ID selection (matches picotool's elf2uf2 ram_style detection):

    Load address                 Family ID    Family name
    0x10000000 - 0x14ffffff      0xE48BFF59   RP2350_ARM_S       (XIP flash)
    0x20000000 - 0x20ffffff      0xE48BFF57   RP2XXX_ABSOLUTE    (RAM/SRAM)

The bootrom uses the family ID to choose its load path. An SRAM-
resident image with the flash family ID is silently rejected on real
hardware after BOOTSEL ejects; with the absolute family ID it is
loaded at the literal address and entered.
"""

import struct
import sys

UF2_MAGIC_START0   = 0x0A324655
UF2_MAGIC_START1   = 0x9E5D5157
UF2_MAGIC_END      = 0x0AB16F30
UF2_FLAG_FAMILY_ID = 0x00002000

# Canonical UF2 family IDs (microsoft/uf2 registry).
FAMILY_RP2350_ARM_S    = 0xE48BFF59
FAMILY_RP2XXX_ABSOLUTE = 0xE48BFF57

PAYLOAD = 256


def family_for(base_addr: int) -> int:
    """Pick the right UF2 family ID from the load address."""
    # XIP flash window on RP2350: 0x10000000..0x14FFFFFF (4 MB on Pico 2).
    if 0x10000000 <= base_addr < 0x15000000:
        return FAMILY_RP2350_ARM_S
    # SRAM region on RP2350: 0x20000000..0x20081FFF (520 KB) plus scratch.
    if 0x20000000 <= base_addr < 0x21000000:
        return FAMILY_RP2XXX_ABSOLUTE
    raise SystemExit(
        f"uf2.py: load address 0x{base_addr:08X} is not in a known RP2350 "
        f"flash or SRAM range; refuse to guess UF2 family ID."
    )


def pack(bin_path: str, base_addr: int, uf2_path: str, family: int) -> None:
    data = open(bin_path, "rb").read()
    pad = (-len(data)) % PAYLOAD
    data += b"\x00" * pad
    nblocks = len(data) // PAYLOAD

    with open(uf2_path, "wb") as out:
        for i in range(nblocks):
            chunk = data[i * PAYLOAD : (i + 1) * PAYLOAD]
            hdr = struct.pack(
                "<IIIIIIII",
                UF2_MAGIC_START0,
                UF2_MAGIC_START1,
                UF2_FLAG_FAMILY_ID,
                base_addr + i * PAYLOAD,
                PAYLOAD,
                i,
                nblocks,
                family,
            )
            block = hdr + chunk + b"\x00" * (476 - PAYLOAD) + struct.pack("<I", UF2_MAGIC_END)
            assert len(block) == 512
            out.write(block)


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write("usage: uf2.py <input.bin> <base_addr> <output.uf2>\n")
        return 1
    base_addr = int(sys.argv[2], 0)
    pack(sys.argv[1], base_addr, sys.argv[3], family_for(base_addr))
    return 0


if __name__ == "__main__":
    sys.exit(main())
