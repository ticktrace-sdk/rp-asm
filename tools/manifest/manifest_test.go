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

package manifest

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	payload := make([]byte, 1024)
	for i := range payload {
		payload[i] = byte(i)
	}
	var f FooterData
	f.Compute(payload)
	f.Seq = 7
	f.Status = StatusStaged
	f.FlavorMin = 0x0001

	enc := f.Marshal()
	if len(enc) != Footer {
		t.Fatalf("marshal length = %d, want %d", len(enc), Footer)
	}

	dec, err := Unmarshal(enc)
	if err != nil {
		t.Fatal(err)
	}
	if dec.PayloadSize != 1024 {
		t.Fatalf("PayloadSize = %d, want 1024", dec.PayloadSize)
	}
	if dec.CRC32 != f.CRC32 {
		t.Fatalf("CRC32 round-trip mismatch")
	}
	if dec.SHA256 != f.SHA256 {
		t.Fatal("SHA256 round-trip mismatch")
	}
	if dec.Seq != 7 {
		t.Fatalf("Seq = %d, want 7", dec.Seq)
	}
	if dec.Status != StatusStaged {
		t.Fatalf("Status = 0x%08X, want STAGED", dec.Status)
	}
	if dec.FlavorMin != 0x0001 {
		t.Fatalf("FlavorMin = 0x%08X", dec.FlavorMin)
	}
	if err := dec.Verify(payload); err != nil {
		t.Fatalf("Verify: %v", err)
	}
}

func TestMagicAtOffsetZero(t *testing.T) {
	// The SSBL reads the magic via a single LDR at the footer base; if we
	// ever moved the field, every flashed SSBL would silently misvalidate.
	// This test is the wire-format-stability canary.
	f := FooterData{}
	enc := f.Marshal()
	got := binary.LittleEndian.Uint32(enc[0:4])
	if got != Magic {
		t.Fatalf("magic at offset 0 = 0x%08X, want 0x%08X", got, Magic)
	}
	if string(enc[0:4]) != "RPBL" {
		t.Fatalf("magic bytes = %q, want %q", enc[0:4], "RPBL")
	}
}

func TestVerifyDetectsCorruption(t *testing.T) {
	payload := []byte("hello bootloader")
	var f FooterData
	f.Compute(payload)

	bad := append([]byte{}, payload...)
	bad[0] ^= 0x01
	if err := f.Verify(bad); err == nil {
		t.Fatal("Verify accepted corrupted payload")
	}

	short := payload[:len(payload)-1]
	if err := f.Verify(short); err == nil {
		t.Fatal("Verify accepted short payload")
	}
}

func TestUnmarshalRejectsBadMagic(t *testing.T) {
	junk := make([]byte, Footer)
	binary.LittleEndian.PutUint32(junk[0:], 0xDEADBEEF)
	if _, err := Unmarshal(junk); err == nil {
		t.Fatal("Unmarshal accepted bad magic")
	}
}

func TestEmptyFlashLooksEmpty(t *testing.T) {
	// Freshly-erased flash is all 0xFF. The status enum reserves 0xFFFFFFFF
	// for that case; ensure our parser treats a magic-mismatch all-FF block
	// as an error (so the SSBL never tries to boot erased flash).
	empty := bytes.Repeat([]byte{0xFF}, Footer)
	if _, err := Unmarshal(empty); err == nil {
		t.Fatal("Unmarshal accepted all-0xFF block")
	}
}
