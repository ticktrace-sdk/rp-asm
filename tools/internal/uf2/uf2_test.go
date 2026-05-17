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

package uf2

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestFamilyFor(t *testing.T) {
	cases := []struct {
		name    string
		addr    uint32
		want    uint32
		wantErr bool
	}{
		{"flash base", 0x10000000, FamilyRP2350ArmS, false},
		{"flash mid", 0x10080000, FamilyRP2350ArmS, false},
		{"flash near top", 0x14FFFFFF, FamilyRP2350ArmS, false},
		{"sram base", 0x20000000, FamilyRP2XXXAbsolute, false},
		{"sram top", 0x20FFFFFF, FamilyRP2XXXAbsolute, false},
		{"junk low", 0x00001000, 0, true},
		{"between flash and sram", 0x18000000, 0, true},
		{"above sram", 0x30000000, 0, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := FamilyFor(c.addr)
			if c.wantErr {
				if err == nil {
					t.Fatalf("addr 0x%08X: want error, got family 0x%08X", c.addr, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("addr 0x%08X: unexpected error %v", c.addr, err)
			}
			if got != c.want {
				t.Fatalf("addr 0x%08X: family = 0x%08X, want 0x%08X", c.addr, got, c.want)
			}
		})
	}
}

func TestPackBlockShape(t *testing.T) {
	// 600 bytes -> 3 blocks (256+256+88 padded to 256).
	in := make([]byte, 600)
	for i := range in {
		in[i] = byte(i)
	}
	var buf bytes.Buffer
	if err := Pack(&buf, in, 0x10000000, FamilyRP2350ArmS); err != nil {
		t.Fatal(err)
	}
	got := buf.Bytes()
	if len(got) != 3*BlockSize {
		t.Fatalf("output = %d bytes, want %d", len(got), 3*BlockSize)
	}
	// Spot-check block 0 header.
	b0 := got[:BlockSize]
	if v := binary.LittleEndian.Uint32(b0[0:]); v != MagicStart0 {
		t.Fatalf("magic0 = 0x%08X, want 0x%08X", v, MagicStart0)
	}
	if v := binary.LittleEndian.Uint32(b0[4:]); v != MagicStart1 {
		t.Fatalf("magic1 = 0x%08X, want 0x%08X", v, MagicStart1)
	}
	if v := binary.LittleEndian.Uint32(b0[8:]); v != FlagFamilyID {
		t.Fatalf("flags = 0x%08X, want 0x%08X", v, FlagFamilyID)
	}
	if v := binary.LittleEndian.Uint32(b0[12:]); v != 0x10000000 {
		t.Fatalf("target_addr block 0 = 0x%08X, want 0x10000000", v)
	}
	if v := binary.LittleEndian.Uint32(b0[16:]); v != Payload {
		t.Fatalf("payload_size = %d, want %d", v, Payload)
	}
	if v := binary.LittleEndian.Uint32(b0[20:]); v != 0 {
		t.Fatalf("block_no = %d, want 0", v)
	}
	if v := binary.LittleEndian.Uint32(b0[24:]); v != 3 {
		t.Fatalf("num_blocks = %d, want 3", v)
	}
	if v := binary.LittleEndian.Uint32(b0[28:]); v != FamilyRP2350ArmS {
		t.Fatalf("family = 0x%08X, want 0x%08X", v, FamilyRP2350ArmS)
	}
	if v := binary.LittleEndian.Uint32(b0[BlockSize-4:]); v != MagicEnd {
		t.Fatalf("end magic = 0x%08X, want 0x%08X", v, MagicEnd)
	}

	// Block 2 target addr.
	b2 := got[2*BlockSize : 3*BlockSize]
	if v := binary.LittleEndian.Uint32(b2[12:]); v != 0x10000200 {
		t.Fatalf("target_addr block 2 = 0x%08X, want 0x10000200", v)
	}
	// Block 2 num_blocks.
	if v := binary.LittleEndian.Uint32(b2[24:]); v != 3 {
		t.Fatalf("num_blocks block 2 = %d, want 3", v)
	}
	// Block 2 payload tail should be zero (input ended at byte 600, so the
	// last 88 input bytes occupy [0..88) of block 2's payload region, and
	// [88..256) is padding).
	for i := 32 + 88; i < 32+Payload; i++ {
		if b2[i] != 0 {
			t.Fatalf("block 2 payload pad byte %d = 0x%02X, want 0", i, b2[i])
		}
	}
}

func TestPackPayloadCopy(t *testing.T) {
	// Single-block input.
	in := make([]byte, Payload)
	for i := range in {
		in[i] = byte(i ^ 0xA5)
	}
	var buf bytes.Buffer
	if err := Pack(&buf, in, 0x20000000, FamilyRP2XXXAbsolute); err != nil {
		t.Fatal(err)
	}
	out := buf.Bytes()
	if len(out) != BlockSize {
		t.Fatalf("len = %d, want %d", len(out), BlockSize)
	}
	if !bytes.Equal(out[32:32+Payload], in) {
		t.Fatal("payload bytes not preserved")
	}
}
