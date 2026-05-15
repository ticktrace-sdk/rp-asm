#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

# tools/keygen.sh - generate dev keys for the RP2350 secure-boot flow.
#
# Produces (in keys/dev/, gitignored):
#   private.pem    secp256k1 private key for image signing (used by `picotool seal`)
#   privateaes.bin 32 random bytes for AES-256 image encryption (M8.2 only)
#   ivsalt.bin     16 random bytes for the IV salt           (M8.2 only)
#
# Idempotent: existing files are not overwritten.  Delete the file (or the
# whole keys/dev/ directory) and re-run to rotate keys.
#
# These are DEVELOPMENT keys - they live in the working tree and are NOT
# burned to OTP.  Never ship them.  For a production flow you'd generate
# the same artifacts on an offline machine and use `picotool otp load` to
# seal them into the chip.

set -euo pipefail

KEYS_DIR="${KEYS_DIR:-keys/dev}"
mkdir -p "$KEYS_DIR"

if [ ! -f "$KEYS_DIR/private.pem" ]; then
    openssl ecparam -name secp256k1 -genkey -noout -out "$KEYS_DIR/private.pem"
    chmod 600 "$KEYS_DIR/private.pem"
    echo "  KEYGEN  $KEYS_DIR/private.pem  (secp256k1)"
else
    echo "  KEEP    $KEYS_DIR/private.pem"
fi

if [ ! -f "$KEYS_DIR/privateaes.bin" ]; then
    dd if=/dev/urandom of="$KEYS_DIR/privateaes.bin" bs=32 count=1 status=none
    chmod 600 "$KEYS_DIR/privateaes.bin"
    echo "  KEYGEN  $KEYS_DIR/privateaes.bin  (32 B AES-256 key)"
else
    echo "  KEEP    $KEYS_DIR/privateaes.bin"
fi

if [ ! -f "$KEYS_DIR/ivsalt.bin" ]; then
    dd if=/dev/urandom of="$KEYS_DIR/ivsalt.bin" bs=16 count=1 status=none
    chmod 600 "$KEYS_DIR/ivsalt.bin"
    echo "  KEYGEN  $KEYS_DIR/ivsalt.bin  (16 B IV salt)"
else
    echo "  KEEP    $KEYS_DIR/ivsalt.bin"
fi
