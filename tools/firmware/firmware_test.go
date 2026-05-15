package firmware

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/amken3d/rp-asm/tools/internal/uf2"
)

func TestPackTwoPieces(t *testing.T) {
	a := bytes.Repeat([]byte{0xAA}, 256)
	b := bytes.Repeat([]byte{0xBB}, 512)
	var buf bytes.Buffer
	err := Pack(&buf, []Piece{
		{Name: "tsbl", LoadAddr: 0x10001000, Data: b},
		{Name: "ssbl", LoadAddr: 0x10000000, Data: a},
	})
	if err != nil {
		t.Fatal(err)
	}
	got := buf.Bytes()
	// 1 block for ssbl + 2 blocks for tsbl = 3 blocks total.
	if len(got) != 3*uf2.BlockSize {
		t.Fatalf("output = %d bytes, want %d", len(got), 3*uf2.BlockSize)
	}
	// Block 0 should be SSBL (lowest address), block_no=0, num_blocks=3.
	b0 := got[:uf2.BlockSize]
	if v := binary.LittleEndian.Uint32(b0[12:]); v != 0x10000000 {
		t.Fatalf("block 0 target = 0x%08X, want 0x10000000", v)
	}
	if v := binary.LittleEndian.Uint32(b0[20:]); v != 0 {
		t.Fatalf("block 0 idx = %d, want 0", v)
	}
	if v := binary.LittleEndian.Uint32(b0[24:]); v != 3 {
		t.Fatalf("block 0 num_blocks = %d, want 3", v)
	}
	// Block 1 should be TSBL, second block (idx=1), target=0x10001000.
	b1 := got[uf2.BlockSize : 2*uf2.BlockSize]
	if v := binary.LittleEndian.Uint32(b1[12:]); v != 0x10001000 {
		t.Fatalf("block 1 target = 0x%08X, want 0x10001000", v)
	}
	if v := binary.LittleEndian.Uint32(b1[20:]); v != 1 {
		t.Fatalf("block 1 idx = %d, want 1", v)
	}
	if v := binary.LittleEndian.Uint32(b1[24:]); v != 3 {
		t.Fatalf("block 1 num_blocks = %d, want 3", v)
	}
}

func TestPackRejectsOverlap(t *testing.T) {
	a := bytes.Repeat([]byte{0xAA}, 4096)
	b := bytes.Repeat([]byte{0xBB}, 256)
	err := Pack(new(bytes.Buffer), []Piece{
		{Name: "a", LoadAddr: 0x10000000, Data: a},
		{Name: "b", LoadAddr: 0x10000800, Data: b}, // inside a
	})
	if err == nil {
		t.Fatal("Pack accepted overlapping pieces")
	}
}

func TestPackEmpty(t *testing.T) {
	if err := Pack(new(bytes.Buffer), nil); err == nil {
		t.Fatal("Pack accepted empty piece list")
	}
}
