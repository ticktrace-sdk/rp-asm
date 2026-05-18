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

package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/amken3d/rp-asm/tools/internal/uf2"
)

const uf2Usage = `usage: rpasm uf2 pack <input.bin> <base_addr> <output.uf2>

base_addr accepts hex (0x...), octal (0...), or decimal.
Family ID is auto-selected from base_addr.
`

func uf2Cmd(args []string) int {
	if len(args) < 1 {
		fmt.Fprint(os.Stderr, uf2Usage)
		return 2
	}
	switch args[0] {
	case "pack":
		return uf2Pack(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "rpasm uf2: unknown subcommand %q\n\n%s", args[0], uf2Usage)
		return 2
	}
}

func uf2Pack(args []string) int {
	if len(args) != 3 {
		fmt.Fprint(os.Stderr, uf2Usage)
		return 2
	}
	inPath := args[0]
	baseStr := args[1]
	outPath := args[2]

	baseAddr, err := parseAddr(baseStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rpasm uf2 pack: bad base_addr %q: %v\n", baseStr, err)
		return 1
	}

	family, err := uf2.FamilyFor(baseAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rpasm uf2 pack: %v\n", err)
		return 1
	}

	data, err := os.ReadFile(inPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rpasm uf2 pack: read %s: %v\n", inPath, err)
		return 1
	}

	out, err := os.Create(outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rpasm uf2 pack: create %s: %v\n", outPath, err)
		return 1
	}
	defer out.Close()
	bw := bufio.NewWriter(out)
	if err := uf2.Pack(bw, data, baseAddr, family); err != nil {
		fmt.Fprintf(os.Stderr, "rpasm uf2 pack: %v\n", err)
		return 1
	}
	if err := bw.Flush(); err != nil {
		fmt.Fprintf(os.Stderr, "rpasm uf2 pack: %v\n", err)
		return 1
	}
	return 0
}

// parseAddr accepts 0x.., 0.., or decimal, matching Python's int(s, 0).
func parseAddr(s string) (uint32, error) {
	s = strings.TrimSpace(s)
	v, err := strconv.ParseUint(s, 0, 32)
	if err != nil {
		return 0, err
	}
	return uint32(v), nil
}
