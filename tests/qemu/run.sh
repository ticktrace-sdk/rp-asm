#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

# =============================================================================
# tests/qemu/run.sh - assemble, link, and run one .S under qemu-system-arm.
#
# Usage:
#   run.sh                              # default: tests/qemu/sanity.S
#   run.sh tests/qemu/cases/foo.S       # arbitrary fixture
#
# Exit code:
#   0  on success (program ran to SYS_EXIT(0) and printed expected token)
#   1  on assemble/link/run failure
#   2  on QEMU not installed
#
# What success means depends on the .S source: the runner only looks at the
# QEMU exit code AND, for sanity.S, the presence of "ok" in stdout.  Tests
# that want to assert specific output should use tests/qemu/test_isa.py.
# =============================================================================

set -u

here="$(cd "$(dirname "$0")" && pwd)"
src="${1:-$here/sanity.S}"
expected="${2:-ok}"

if ! command -v qemu-system-arm >/dev/null 2>&1; then
    echo "SKIP: qemu-system-arm not installed" >&2
    exit 2
fi

if ! command -v arm-none-eabi-as >/dev/null 2>&1; then
    echo "FAIL: arm-none-eabi-as not installed" >&2
    exit 1
fi

build_dir="$(mktemp -d)"
trap "rm -rf $build_dir" EXIT

name="$(basename "${src%.S}")"
obj="$build_dir/$name.o"
elf="$build_dir/$name.elf"

# Assemble
if ! arm-none-eabi-as -mcpu=cortex-m33 -mthumb -mimplicit-it=always \
        -o "$obj" "$src" 2>&1; then
    echo "FAIL: assemble error in $src" >&2
    exit 1
fi

# Link with our QEMU script
if ! arm-none-eabi-ld -T "$here/qemu.ld" -nostdlib -o "$elf" "$obj" 2>&1; then
    echo "FAIL: link error for $src" >&2
    exit 1
fi

# Run under QEMU.  -no-reboot is essential: without it, SYS_EXIT could be
# interpreted as a reset request on some boards.
out="$(qemu-system-arm \
        -M mps2-an505 \
        -cpu cortex-m33 \
        -nographic \
        -monitor none \
        -semihosting-config enable=on,target=native \
        -kernel "$elf" \
        -no-reboot \
        2>&1)"
rc=$?

echo "$out"

if [ $rc -ne 0 ]; then
    echo "FAIL: qemu exited with rc=$rc on $src" >&2
    exit 1
fi

if [ -n "$expected" ] && ! grep -Fq "$expected" <<<"$out"; then
    echo "FAIL: expected '$expected' in QEMU output for $src" >&2
    exit 1
fi

echo "PASS: $name"
exit 0
