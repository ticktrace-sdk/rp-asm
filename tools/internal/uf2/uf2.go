// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Amken LLC <https://www.amken.us>
//
// This file is part of the ticktrace Assembly SDK.
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

// Package uf2 implements the Microsoft UF2 container format as used by the
// RP2350 mask-ROM bootrom.
//
// Each UF2 block is 512 bytes, holding up to 476 bytes of payload (we always
// emit 256-byte payloads to match picotool's elf2uf2 and tools/uf2.py).
//
// Format reference: https://github.com/microsoft/uf2
package uf2

import (
	"encoding/binary"
	"fmt"
	"io"
)

const (
	MagicStart0 uint32 = 0x0A324655
	MagicStart1 uint32 = 0x9E5D5157
	MagicEnd    uint32 = 0x0AB16F30

	FlagFamilyID uint32 = 0x00002000

	// Payload bytes per block. Matches picotool and tools/uf2.py.
	Payload = 256

	// BlockSize is the on-disk size of a UF2 block.
	BlockSize = 512
)

// Canonical UF2 family IDs from the microsoft/uf2 registry.
const (
	FamilyRP2350ArmS    uint32 = 0xE48BFF59
	FamilyRP2XXXAbsolute uint32 = 0xE48BFF57
)

// FamilyFor selects the correct UF2 family ID from the image's load address.
// This mirrors picotool's elf2uf2 ram_style detection: SRAM-resident images
// must use the absolute family ID, otherwise the bootrom silently rejects
// them on real hardware after BOOTSEL ejects the drive.
func FamilyFor(addr uint32) (uint32, error) {
	switch {
	case addr >= 0x10000000 && addr < 0x15000000:
		return FamilyRP2350ArmS, nil
	case addr >= 0x20000000 && addr < 0x21000000:
		return FamilyRP2XXXAbsolute, nil
	default:
		return 0, fmt.Errorf("load address 0x%08X is not in a known RP2350 flash or SRAM range; refuse to guess UF2 family ID", addr)
	}
}

// Pack writes data to w as a UF2 stream loaded at baseAddr with the given
// family ID. data is zero-padded to a multiple of Payload before packing.
func Pack(w io.Writer, data []byte, baseAddr, family uint32) error {
	// Zero-pad to Payload multiple.
	if rem := len(data) % Payload; rem != 0 {
		data = append(data, make([]byte, Payload-rem)...)
	}
	nblocks := uint32(len(data) / Payload)

	var block [BlockSize]byte
	for i := uint32(0); i < nblocks; i++ {
		// Zero the block (the previous iteration's trailing zeros are fine,
		// but a fresh image makes the intent explicit and costs nothing).
		for j := range block {
			block[j] = 0
		}

		binary.LittleEndian.PutUint32(block[0:], MagicStart0)
		binary.LittleEndian.PutUint32(block[4:], MagicStart1)
		binary.LittleEndian.PutUint32(block[8:], FlagFamilyID)
		binary.LittleEndian.PutUint32(block[12:], baseAddr+i*Payload)
		binary.LittleEndian.PutUint32(block[16:], Payload)
		binary.LittleEndian.PutUint32(block[20:], i)
		binary.LittleEndian.PutUint32(block[24:], nblocks)
		binary.LittleEndian.PutUint32(block[28:], family)

		copy(block[32:32+Payload], data[i*Payload:(i+1)*Payload])
		// Trailing bytes [32+Payload : BlockSize-4] are already zero.
		binary.LittleEndian.PutUint32(block[BlockSize-4:], MagicEnd)

		if _, err := w.Write(block[:]); err != nil {
			return err
		}
	}
	return nil
}
