// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Amken LLC <https://amken.io>
//
// This file is part of the Amken RP2350 Assembly SDK.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public
// License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//
// A commercial license is available from Amken LLC for use cases that
// cannot comply with the AGPL. See COMMERCIAL-LICENSE.md.

// Package manifest serialises the rp-asm bootloader slot footer.
//
// The layout matches include/bootloader.inc byte-for-byte. Any change here
// requires the corresponding change there and a rebuild of any flashed
// SSBL/TSBL/app.
package manifest

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
)

const (
	// Footer is the on-disk size of a slot footer. The footer occupies the
	// last 256 bytes of a slot; the payload it describes occupies
	// [slot_base, slot_base + PayloadSize).
	Footer = 256

	// Magic is little-endian "RPBL" — sentinel that every footer starts with.
	Magic uint32 = 0x4C425052

	// FormatVersion is the current footer layout version.
	FormatVersion uint32 = 1
)

// Field offsets inside the 256-byte footer. Mirrored from
// include/bootloader.inc (BL_FOOTER_OFF_*).
const (
	offMagic        = 0x00
	offFormatVer    = 0x04
	offPayloadSize  = 0x08
	offCRC32        = 0x0C
	offDigest       = 0x10
	offSignature    = 0x30
	offSeq          = 0x70
	offStatus       = 0x74
	offFlavorMin    = 0x78
	offReservedEnd  = Footer
)

// Status values. Each transition is a single bit-clear so a flashed footer
// can be updated in place without erasing the sector.
type Status uint32

const (
	StatusEmpty  Status = 0xFFFFFFFF
	StatusStaged Status = 0xFFFFFFFE
	StatusTrying Status = 0xFFFFFFFC
	StatusGood   Status = 0xFFFFFFF8
	StatusBad    Status = 0x00000000
)

// Footer represents the high-level fields of a slot footer. Anything not
// represented here is reserved-and-zero.
type FooterData struct {
	PayloadSize uint32
	CRC32       uint32
	SHA256      [32]byte
	Signature   [64]byte
	Seq         uint32
	Status      Status
	FlavorMin   uint32
}

// Compute fills CRC32 and SHA256 over payload[0:size]. PayloadSize is set to
// len(payload) and any other field that was left zero stays zero.
func (f *FooterData) Compute(payload []byte) {
	f.PayloadSize = uint32(len(payload))
	f.CRC32 = crc32.ChecksumIEEE(payload)
	f.SHA256 = sha256.Sum256(payload)
}

// Marshal returns the 256-byte on-disk representation of f.
func (f FooterData) Marshal() []byte {
	var b [Footer]byte
	binary.LittleEndian.PutUint32(b[offMagic:], Magic)
	binary.LittleEndian.PutUint32(b[offFormatVer:], FormatVersion)
	binary.LittleEndian.PutUint32(b[offPayloadSize:], f.PayloadSize)
	binary.LittleEndian.PutUint32(b[offCRC32:], f.CRC32)
	copy(b[offDigest:offDigest+32], f.SHA256[:])
	copy(b[offSignature:offSignature+64], f.Signature[:])
	binary.LittleEndian.PutUint32(b[offSeq:], f.Seq)
	binary.LittleEndian.PutUint32(b[offStatus:], uint32(f.Status))
	binary.LittleEndian.PutUint32(b[offFlavorMin:], f.FlavorMin)
	return b[:]
}

// Unmarshal parses a 256-byte footer. It verifies the magic and version
// but does not (re)compute the CRC/digest — callers needing integrity
// validation should call Verify with the payload.
func Unmarshal(b []byte) (FooterData, error) {
	if len(b) != Footer {
		return FooterData{}, fmt.Errorf("footer: want %d bytes, got %d", Footer, len(b))
	}
	if got := binary.LittleEndian.Uint32(b[offMagic:]); got != Magic {
		return FooterData{}, fmt.Errorf("footer: bad magic 0x%08X (want 0x%08X)", got, Magic)
	}
	if got := binary.LittleEndian.Uint32(b[offFormatVer:]); got != FormatVersion {
		return FooterData{}, fmt.Errorf("footer: unsupported format version %d (want %d)", got, FormatVersion)
	}
	var f FooterData
	f.PayloadSize = binary.LittleEndian.Uint32(b[offPayloadSize:])
	f.CRC32 = binary.LittleEndian.Uint32(b[offCRC32:])
	copy(f.SHA256[:], b[offDigest:offDigest+32])
	copy(f.Signature[:], b[offSignature:offSignature+64])
	f.Seq = binary.LittleEndian.Uint32(b[offSeq:])
	f.Status = Status(binary.LittleEndian.Uint32(b[offStatus:]))
	f.FlavorMin = binary.LittleEndian.Uint32(b[offFlavorMin:])
	return f, nil
}

// Verify checks that the footer's CRC32 (and SHA256, if non-zero) match the
// supplied payload. Returns nil on success.
func (f FooterData) Verify(payload []byte) error {
	if uint32(len(payload)) != f.PayloadSize {
		return fmt.Errorf("footer: payload size mismatch (footer=%d, supplied=%d)", f.PayloadSize, len(payload))
	}
	if got := crc32.ChecksumIEEE(payload); got != f.CRC32 {
		return fmt.Errorf("footer: CRC32 mismatch (footer=0x%08X, computed=0x%08X)", f.CRC32, got)
	}
	var zero [32]byte
	if f.SHA256 != zero {
		got := sha256.Sum256(payload)
		if got != f.SHA256 {
			return errors.New("footer: SHA-256 mismatch")
		}
	}
	return nil
}
