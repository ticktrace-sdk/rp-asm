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

// Command rpasm is the ticktrace developer tool. It bundles every host-side
// utility the SDK needs (UF2 packing, slot-header manifests, firmware image
// concatenation, USB CDC DFU client) into a single static binary so users
// don't have to chase Python deps.
//
// Subcommands:
//
//	rpasm uf2 pack <input.bin> <base_addr> <output.uf2>
//	    Pack a raw binary into a UF2 image. Family ID is auto-selected from
//	    base_addr (SRAM or XIP flash range).
//
// Future subcommands (Phase 1b+): mkmanifest, mkfirmware, dfu, info.
package main

import (
	"fmt"
	"os"
)

const usage = `rpasm - ticktrace developer tool

usage: rpasm <command> [args]

commands:
  uf2 pack <input.bin> <base_addr> <output.uf2>
      Pack a raw binary into a UF2 image.

  mkmanifest <input.bin> -o <output.footer.bin> [-status ...] [-seq N]
      Compute a 256-byte slot footer (magic, CRC32, SHA-256) over the
      input. Used by the bootloader build to seal SSBL/TSBL/app slots.

  mkfirmware -o <output.uf2> <addr>:<bin> [<addr>:<bin> ...]
      Concatenate multiple binaries (each at its load address) into a
      single UF2 image. Used to produce one-drag factory firmware
      (SSBL + TSBL + app + footers).

  help
      Show this message.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	switch os.Args[1] {
	case "uf2":
		os.Exit(uf2Cmd(os.Args[2:]))
	case "mkmanifest":
		os.Exit(mkmanifestCmd(os.Args[2:]))
	case "mkfirmware":
		os.Exit(mkfirmwareCmd(os.Args[2:]))
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "rpasm: unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}
}
