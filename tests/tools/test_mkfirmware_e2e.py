"""End-to-end tooling test: synthetic SSBL + TSBL + app, sealed with
mkmanifest, combined via mkfirmware, then dissected from the UF2 to
verify every byte ended up where the bootloader will look for it.

Doesn't require the arm-none-eabi toolchain — exercises only the host-
side tooling. The on-target boot chain will reuse exactly these formats.
"""

import os
import struct
import subprocess
import tempfile
import zlib

import pytest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RPASM = os.path.join(REPO, "tools", "bin", "rpasm")

# Mirrors include/bootloader.inc.
SSBL_BASE        = 0x10000000
TSBL_BASE        = 0x10001000
TSBL_FOOTER_ADDR = 0x10006F00
APP_BASE         = 0x10008000
APP_FOOTER_ADDR  = 0x1007FF00

FOOTER_SIZE  = 256
FOOTER_MAGIC = 0x4C425052  # "RPBL"

pytestmark = pytest.mark.skipif(
    not (os.path.isfile(RPASM) and os.access(RPASM, os.X_OK)),
    reason="tools/bin/rpasm not built; run `make tools` first",
)


def _run(*args):
    subprocess.run(args, check=True)


def _parse_uf2(blob: bytes) -> dict[int, bytes]:
    """Return {byte_address: data_byte_value} for every byte the UF2 covers.

    Easier to spot-check than reconstructing contiguous segments, and
    catches address-arithmetic bugs in mkfirmware.
    """
    assert len(blob) % 512 == 0
    out: dict[int, bytes] = {}
    for i in range(0, len(blob), 512):
        block = blob[i : i + 512]
        magic0, magic1, _flags, addr, size, _idx, _total, _fam = \
            struct.unpack("<IIIIIIII", block[:32])
        assert magic0 == 0x0A324655
        assert magic1 == 0x9E5D5157
        assert size == 256
        payload = block[32 : 32 + 256]
        for j in range(256):
            out[addr + j] = payload[j]
    return out


def test_full_firmware_image():
    with tempfile.TemporaryDirectory() as td:
        # Synthetic SSBL = 0xAA * 4 KiB.
        ssbl = os.path.join(td, "ssbl.bin")
        with open(ssbl, "wb") as f:
            f.write(bytes([0xAA] * 4096))
        # Synthetic TSBL = 0xBB * (24 KiB - 256). The footer occupies the
        # last 256 bytes of the slot, so the TSBL .bin must fit before it.
        tsbl_size = 24 * 1024 - 256
        tsbl = os.path.join(td, "tsbl.bin")
        with open(tsbl, "wb") as f:
            f.write(bytes([0xBB] * tsbl_size))
        # Synthetic app = 1234 bytes of incrementing values.
        app = os.path.join(td, "app.bin")
        app_payload = bytes(i & 0xFF for i in range(1234))
        with open(app, "wb") as f:
            f.write(app_payload)

        # Seal TSBL and app. (SSBL doesn't have a footer in Phase 1 — the
        # bootrom validates it via IMAGE_DEF, and there's no upstream stage
        # that needs to verify it.)
        tsbl_ft = os.path.join(td, "tsbl.footer.bin")
        app_ft = os.path.join(td, "app.footer.bin")
        _run(RPASM, "mkmanifest", tsbl, "-o", tsbl_ft, "-status", "good")
        _run(RPASM, "mkmanifest", app, "-o", app_ft, "-status", "good", "-seq", "1")

        # Combine.
        firmware = os.path.join(td, "firmware.uf2")
        _run(
            RPASM, "mkfirmware", "-o", firmware,
            f"{SSBL_BASE:#x}:{ssbl}",
            f"{TSBL_BASE:#x}:{tsbl}",
            f"{TSBL_FOOTER_ADDR:#x}:{tsbl_ft}",
            f"{APP_BASE:#x}:{app}",
            f"{APP_FOOTER_ADDR:#x}:{app_ft}",
        )

        # Verify.
        with open(firmware, "rb") as f:
            uf2_blob = f.read()
        mem = _parse_uf2(uf2_blob)

        # SSBL bytes.
        for off in range(4096):
            assert mem[SSBL_BASE + off] == 0xAA, f"SSBL miss at +0x{off:X}"
        # TSBL bytes (up to footer).
        for off in range(tsbl_size):
            assert mem[TSBL_BASE + off] == 0xBB, f"TSBL miss at +0x{off:X}"
        # App bytes.
        for off, b in enumerate(app_payload):
            assert mem[APP_BASE + off] == b, f"app miss at +0x{off:X}"

        # App footer magic at the well-known address.
        magic_bytes = bytes(mem[APP_FOOTER_ADDR + i] for i in range(4))
        assert magic_bytes == b"RPBL", f"app footer magic = {magic_bytes!r}"

        # App footer CRC32 matches what the SSBL/TSBL will compute on-chip.
        crc_bytes = bytes(mem[APP_FOOTER_ADDR + 0x0C + i] for i in range(4))
        crc = struct.unpack("<I", crc_bytes)[0]
        assert crc == zlib.crc32(app_payload) & 0xFFFFFFFF

        size_bytes = bytes(mem[APP_FOOTER_ADDR + 0x08 + i] for i in range(4))
        assert struct.unpack("<I", size_bytes)[0] == len(app_payload)

        # TSBL footer also reachable and valid.
        magic_bytes = bytes(mem[TSBL_FOOTER_ADDR + i] for i in range(4))
        assert magic_bytes == b"RPBL"
        crc_bytes = bytes(mem[TSBL_FOOTER_ADDR + 0x0C + i] for i in range(4))
        crc = struct.unpack("<I", crc_bytes)[0]
        assert crc == zlib.crc32(b"\xBB" * tsbl_size) & 0xFFFFFFFF


def test_mkfirmware_rejects_overlap():
    with tempfile.TemporaryDirectory() as td:
        a = os.path.join(td, "a.bin")
        b = os.path.join(td, "b.bin")
        with open(a, "wb") as f:
            f.write(b"\x00" * 4096)
        with open(b, "wb") as f:
            f.write(b"\x00" * 256)
        out = os.path.join(td, "out.uf2")
        result = subprocess.run(
            [RPASM, "mkfirmware", "-o", out,
             f"0x10000000:{a}", f"0x10000800:{b}"],
            capture_output=True,
        )
        assert result.returncode != 0
        assert b"overlap" in result.stderr


def test_mkmanifest_status_round_trip():
    with tempfile.TemporaryDirectory() as td:
        payload = os.path.join(td, "p.bin")
        with open(payload, "wb") as f:
            f.write(b"hello bootloader\n")
        ft = os.path.join(td, "p.footer.bin")
        _run(RPASM, "mkmanifest", payload, "-o", ft, "-status", "trying", "-seq", "42")
        with open(ft, "rb") as f:
            data = f.read()
        assert len(data) == FOOTER_SIZE
        magic, ver, sz, crc = struct.unpack("<IIII", data[:16])
        assert magic == FOOTER_MAGIC
        assert ver == 1
        assert sz == 17
        assert crc == zlib.crc32(b"hello bootloader\n") & 0xFFFFFFFF
        seq, status = struct.unpack("<II", data[0x70:0x78])
        assert seq == 42
        assert status == 0xFFFFFFFC  # STATUS_TRYING
