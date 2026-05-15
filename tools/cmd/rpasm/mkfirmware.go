package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/amken3d/rp-asm/tools/internal/firmware"
)

const mkfirmwareUsage = `usage: rpasm mkfirmware -o <output.uf2> <addr>:<file.bin> [<addr>:<file.bin> ...]

Concatenates one or more binaries into a single UF2 image with non-contiguous
load regions. Used to produce a one-drag-drop factory firmware containing
SSBL + TSBL + app(s) + footers.

example (Phase 1, -bypass):
  rpasm mkfirmware -o build/firmware.uf2 \
      0x10000000:build/ssbl.bin \
      0x10001000:build/tsbl_bypass.bin \
      0x10008000:build/app.bin \
      0x1007FF00:build/app.footer.bin
`

func mkfirmwareCmd(args []string) int {
	var (
		out        string
		positional []string
	)
	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "-h", "--help":
			fmt.Print(mkfirmwareUsage)
			return 0
		case "-o":
			if i+1 >= len(args) {
				return mkfirmwareErr("-o requires a value")
			}
			out = args[i+1]
			i += 2
		default:
			if strings.HasPrefix(a, "-") {
				return mkfirmwareErr(fmt.Sprintf("unknown flag %q", a))
			}
			positional = append(positional, a)
			i++
		}
	}
	if out == "" || len(positional) == 0 {
		fmt.Fprint(os.Stderr, mkfirmwareUsage)
		return 2
	}

	pieces := make([]firmware.Piece, 0, len(positional))
	for _, spec := range positional {
		idx := strings.IndexByte(spec, ':')
		if idx <= 0 || idx == len(spec)-1 {
			return mkfirmwareErr(fmt.Sprintf("bad piece spec %q (want <addr>:<file>)", spec))
		}
		addrStr := spec[:idx]
		path := spec[idx+1:]
		addr, err := strconv.ParseUint(strings.TrimSpace(addrStr), 0, 32)
		if err != nil {
			return mkfirmwareErr(fmt.Sprintf("piece %q: bad addr: %v", spec, err))
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return mkfirmwareErr(fmt.Sprintf("piece %q: read: %v", spec, err))
		}
		pieces = append(pieces, firmware.Piece{
			Name:     path,
			LoadAddr: uint32(addr),
			Data:     data,
		})
	}

	outFile, err := os.Create(out)
	if err != nil {
		return mkfirmwareErr(fmt.Sprintf("create %s: %v", out, err))
	}
	defer outFile.Close()
	bw := bufio.NewWriter(outFile)
	if err := firmware.Pack(bw, pieces); err != nil {
		return mkfirmwareErr(err.Error())
	}
	if err := bw.Flush(); err != nil {
		return mkfirmwareErr(err.Error())
	}
	return 0
}

func mkfirmwareErr(msg string) int {
	fmt.Fprintf(os.Stderr, "rpasm mkfirmware: %s\n\n%s", msg, mkfirmwareUsage)
	return 2
}
