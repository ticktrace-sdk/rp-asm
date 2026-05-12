#!/usr/bin/env bash
# =============================================================================
# tests/renode/run.sh - run the T3 Renode integration test for v0.1.
#
# Behaviour:
#   - if `renode` isn't installed, prints a SKIP line and exits 0 so CI
#     keeps moving (T3 is a "slow tier" - install issues should not gate
#     PRs).  Install instructions live in tests/renode/README.md.
#   - otherwise drives blinky.resc, captures the console, and asserts on:
#       * UART0 emitted "rp-asm v0.1"  (banner)
#       * at least 4 LED toggles observed via the SIO XOR watchpoint
# =============================================================================

set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

if ! command -v renode >/dev/null 2>&1; then
    echo "SKIP: renode not installed (see tests/renode/README.md)"
    exit 0
fi

# Make sure the firmware exists; if not, let the make target build it.
if [ ! -f "$repo/build/blinky.elf" ]; then
    echo "INFO: build/blinky.elf missing - building..."
    make -C "$repo" >/dev/null
fi

cd "$repo"
log="$(mktemp)"
trap "rm -f $log" EXIT

# Renode flags:
#   --console      - keep stdout in the foreground (no curses UI)
#   --disable-xwt  - no GUI/analyzer windows
#   --plain        - plain text, no colour codes
#   -e             - run the given monitor command (semicolon-separated)
#
# We exit with `q` after the script finishes.  If the script gets stuck the
# `timeout` envelope will kill it.
timeout 60 renode --console --disable-xwt --plain \
    -e "i @tests/renode/blinky.resc; q" \
    >"$log" 2>&1
rc=$?

echo "----- Renode log (last 40 lines) -----"
tail -40 "$log"
echo "--------------------------------------"

if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then
    echo "FAIL: renode exited rc=$rc"
    exit 1
fi

# Banner check
if ! grep -q "rp-asm v0.1" "$log"; then
    echo "FAIL: UART output did not contain 'rp-asm v0.1' banner"
    exit 1
fi

# LED toggle check - InfoLog 'LED_TOGGLE' fires once per XOR store.
toggles="$(grep -c 'LED_TOGGLE' "$log" || true)"
if [ "$toggles" -lt 4 ]; then
    echo "FAIL: only $toggles LED toggle(s) observed (need >= 4)"
    exit 1
fi

echo "PASS: renode T3 (banner OK, $toggles LED toggles)"
exit 0
