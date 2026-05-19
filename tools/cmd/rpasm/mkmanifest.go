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
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/ticktrace-sdk/rp-asm/tools/manifest"
)

const mkmanifestUsage = `usage: rpasm mkmanifest <input.bin> -o <output.footer.bin> [flags]

Computes a 256-byte slot footer (magic "RPBL", CRC32, SHA-256, status,
flavor_min) over input.bin and writes it to output.footer.bin.

flags:
  -o <path>           output footer path (required)
  -status <name>      empty|staged|trying|good|bad   (default: staged)
  -seq <n>            monotonic counter for -ab slot selection (default: 0)
  -flavor-min <hex>   minimum TSBL flavor bitmap (default: 0)
`

func mkmanifestCmd(args []string) int {
	var (
		out       string
		statusStr = "staged"
		seq       uint64
		flavorStr string
		positional []string
	)

	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "-h", "--help":
			fmt.Print(mkmanifestUsage)
			return 0
		case "-o":
			if i+1 >= len(args) {
				return mkmanifestErr("-o requires a value")
			}
			out = args[i+1]
			i += 2
		case "-status":
			if i+1 >= len(args) {
				return mkmanifestErr("-status requires a value")
			}
			statusStr = args[i+1]
			i += 2
		case "-seq":
			if i+1 >= len(args) {
				return mkmanifestErr("-seq requires a value")
			}
			v, err := strconv.ParseUint(args[i+1], 0, 32)
			if err != nil {
				return mkmanifestErr(fmt.Sprintf("bad -seq: %v", err))
			}
			seq = v
			i += 2
		case "-flavor-min":
			if i+1 >= len(args) {
				return mkmanifestErr("-flavor-min requires a value")
			}
			flavorStr = args[i+1]
			i += 2
		default:
			if strings.HasPrefix(a, "-") {
				return mkmanifestErr(fmt.Sprintf("unknown flag %q", a))
			}
			positional = append(positional, a)
			i++
		}
	}

	if len(positional) != 1 || out == "" {
		fmt.Fprint(os.Stderr, mkmanifestUsage)
		return 2
	}

	status, err := parseStatus(statusStr)
	if err != nil {
		return mkmanifestErr(err.Error())
	}
	var flavorMin uint64
	if flavorStr != "" {
		v, err := strconv.ParseUint(flavorStr, 0, 32)
		if err != nil {
			return mkmanifestErr(fmt.Sprintf("bad -flavor-min: %v", err))
		}
		flavorMin = v
	}

	payload, err := os.ReadFile(positional[0])
	if err != nil {
		return mkmanifestErr(fmt.Sprintf("read %s: %v", positional[0], err))
	}

	var f manifest.FooterData
	f.Compute(payload)
	f.Seq = uint32(seq)
	f.Status = status
	f.FlavorMin = uint32(flavorMin)

	if err := os.WriteFile(out, f.Marshal(), 0644); err != nil {
		return mkmanifestErr(fmt.Sprintf("write %s: %v", out, err))
	}
	fmt.Fprintf(os.Stderr, "  MFEST   %s  (size=%d crc32=0x%08X)\n",
		out, f.PayloadSize, f.CRC32)
	return 0
}

func parseStatus(s string) (manifest.Status, error) {
	switch strings.ToLower(s) {
	case "empty":
		return manifest.StatusEmpty, nil
	case "staged":
		return manifest.StatusStaged, nil
	case "trying":
		return manifest.StatusTrying, nil
	case "good":
		return manifest.StatusGood, nil
	case "bad":
		return manifest.StatusBad, nil
	default:
		return 0, fmt.Errorf("unknown -status %q (want empty|staged|trying|good|bad)", s)
	}
}

func mkmanifestErr(msg string) int {
	fmt.Fprintf(os.Stderr, "rpasm mkmanifest: %s\n\n%s", msg, mkmanifestUsage)
	return 2
}
