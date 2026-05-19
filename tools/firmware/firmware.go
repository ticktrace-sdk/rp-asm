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

// Package firmware composes multiple binaries into a single UF2 image with
// non-contiguous load regions, one per stage in the boot chain.
//
// Each piece is described by its load address and bytes. UF2 blocks are
// emitted strictly in input order; the bootrom programs flash sector-by-
// sector regardless of order, but keeping it sorted makes hex dumps easier
// to read and matches picotool's output.
package firmware

import (
	"fmt"
	"io"
	"sort"

	"github.com/ticktrace-sdk/rp-asm/tools/internal/uf2"
)

// Piece is a contiguous binary segment loaded at LoadAddr.
type Piece struct {
	Name     string // human-readable, used only in error messages
	LoadAddr uint32
	Data     []byte
}

// Pack writes all pieces as a single UF2 stream to w. The block count in
// each block's header is the total across all pieces (this matches what
// picotool produces and what the bootrom expects).
//
// Pieces may not overlap; pieces are emitted in ascending LoadAddr order.
// All pieces must fall in either the XIP flash range or the SRAM range
// (they can be mixed: e.g. a flash SSBL + a SRAM .data shadow), and the
// UF2 family ID is selected per-piece by its LoadAddr.
func Pack(w io.Writer, pieces []Piece) error {
	if len(pieces) == 0 {
		return fmt.Errorf("firmware: no pieces to pack")
	}

	// Defensive copy + sort by LoadAddr.
	sorted := append([]Piece(nil), pieces...)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].LoadAddr < sorted[j].LoadAddr
	})

	// Detect overlap.
	for i := 1; i < len(sorted); i++ {
		prev := sorted[i-1]
		prevEnd := uint64(prev.LoadAddr) + uint64(len(prev.Data))
		if uint64(sorted[i].LoadAddr) < prevEnd {
			return fmt.Errorf("firmware: piece %q at 0x%08X overlaps %q ending at 0x%08X",
				sorted[i].Name, sorted[i].LoadAddr, prev.Name, prevEnd)
		}
	}

	// Compute total block count up front so every block header carries it.
	total := uint32(0)
	for _, p := range sorted {
		total += blockCount(p.Data)
	}

	// Emit. We can't use uf2.Pack directly because it computes block counts
	// locally; we re-implement the inner loop with a piece-global counter.
	idx := uint32(0)
	for _, p := range sorted {
		fam, err := uf2.FamilyFor(p.LoadAddr)
		if err != nil {
			return fmt.Errorf("firmware: piece %q: %w", p.Name, err)
		}
		if err := writePiece(w, p.LoadAddr, p.Data, fam, &idx, total); err != nil {
			return err
		}
	}
	return nil
}

// blockCount is the number of 256-byte UF2 blocks a piece will produce.
func blockCount(data []byte) uint32 {
	if len(data) == 0 {
		return 0
	}
	return uint32((len(data) + uf2.Payload - 1) / uf2.Payload)
}

func writePiece(w io.Writer, base uint32, data []byte, family uint32, idx *uint32, total uint32) error {
	// Zero-pad to Payload multiple.
	if rem := len(data) % uf2.Payload; rem != 0 {
		data = append(data, make([]byte, uf2.Payload-rem)...)
	}
	n := uint32(len(data) / uf2.Payload)
	var block [uf2.BlockSize]byte
	for i := uint32(0); i < n; i++ {
		for j := range block {
			block[j] = 0
		}
		putU32(block[0:], uf2.MagicStart0)
		putU32(block[4:], uf2.MagicStart1)
		putU32(block[8:], uf2.FlagFamilyID)
		putU32(block[12:], base+i*uf2.Payload)
		putU32(block[16:], uf2.Payload)
		putU32(block[20:], *idx)
		putU32(block[24:], total)
		putU32(block[28:], family)
		copy(block[32:32+uf2.Payload], data[i*uf2.Payload:(i+1)*uf2.Payload])
		putU32(block[uf2.BlockSize-4:], uf2.MagicEnd)
		if _, err := w.Write(block[:]); err != nil {
			return err
		}
		*idx++
	}
	return nil
}

func putU32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}
