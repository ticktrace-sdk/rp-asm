#!/usr/bin/env python3
"""uf2.py - tiny .bin -> .uf2 packer for RP2350 Arm-Secure SRAM images.

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
"""

import struct
import sys

UF2_MAGIC_START0   = 0x0A324655
UF2_MAGIC_START1   = 0x9E5D5157
UF2_MAGIC_END      = 0x0AB16F30
UF2_FLAG_FAMILY_ID = 0x00002000

# picotool family IDs for RP2350.  rp2350-arm-s matches the IMAGE_DEF flags
# we emit in startup.S (chip=RP2350, cpu=Arm, security=S).
FAMILY_RP2350_ARM_S = 0xE48BFF59

PAYLOAD = 256


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
    pack(sys.argv[1], int(sys.argv[2], 0), sys.argv[3], FAMILY_RP2350_ARM_S)
    return 0


if __name__ == "__main__":
    sys.exit(main())
