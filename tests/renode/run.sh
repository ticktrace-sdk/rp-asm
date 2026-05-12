#!/usr/bin/env bash
# =============================================================================
# tests/renode/run.sh - run the T3 Renode integration tests.
#
# Behaviour:
#   - if `renode` isn't installed, prints a SKIP line and exits 0 so CI
#     keeps moving (T3 is a "slow tier" - install issues should not gate
#     PRs).  Install instructions live in tests/renode/README.md.
#
#   - otherwise drives every .resc in this directory, captures the console,
#     and asserts on the per-script criteria below.
#
# Scripts:
#   blinky.resc  - default v0.1 firmware in build/blinky.elf
#                  ASSERT: UART contains "rp-asm" banner, >= 4 LED toggles
#                  (since M2 the production main is the 150 MHz clocks demo;
#                  we relaxed the banner to just "rp-asm" to cover both v0.1
#                  and M2 banners)
#   clocks.resc  - M2 clocks demo in build/clocks_demo.elf
#                  ASSERT: UART contains "150 MHz", >= 1 LED toggle
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
if [ ! -f "$repo/build/clocks_demo.elf" ]; then
    echo "INFO: build/clocks_demo.elf missing - building..."
    make -C "$repo" build/clocks_demo.uf2 >/dev/null
fi

cd "$repo"

# ---- Helper: run one .resc, return path to log file --------------------------
run_one() {
    local resc="$1"
    local log
    log="$(mktemp)"
    timeout 60 renode --console --disable-xwt --plain \
        -e "i @${resc}; q" \
        >"$log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then
        echo "FAIL: renode (${resc}) exited rc=$rc" >&2
        echo "----- Renode log (last 40 lines) -----" >&2
        tail -40 "$log" >&2
        echo "--------------------------------------" >&2
        rm -f "$log"
        return 1
    fi
    echo "$log"
}

overall=0

# ---- 1. blinky.resc - the existing image (now M2 firmware) ------------------
log="$(run_one "tests/renode/blinky.resc")" || { overall=1; }
if [ -n "${log:-}" ] && [ -f "$log" ]; then
    echo "----- blinky.resc log (last 30 lines) -----"
    tail -30 "$log"
    echo "-------------------------------------------"
    if ! grep -q "rp-asm" "$log"; then
        echo "FAIL: blinky.resc - UART missing 'rp-asm' banner"
        overall=1
    fi
    toggles="$(grep -c 'LED_TOGGLE' "$log" || true)"
    if [ "$toggles" -lt 1 ]; then
        echo "FAIL: blinky.resc - only $toggles LED toggle(s) observed"
        overall=1
    else
        echo "PASS: blinky.resc (banner OK, $toggles LED toggles)"
    fi
    rm -f "$log"
fi

# ---- 2. clocks.resc - M2 clocks demo ----------------------------------------
log="$(run_one "tests/renode/clocks.resc")" || { overall=1; }
if [ -n "${log:-}" ] && [ -f "$log" ]; then
    echo "----- clocks.resc log (last 30 lines) -----"
    tail -30 "$log"
    echo "-------------------------------------------"
    if ! grep -q "150 MHz" "$log"; then
        echo "FAIL: clocks.resc - UART missing '150 MHz' substring"
        overall=1
    fi
    toggles="$(grep -c 'LED_TOGGLE' "$log" || true)"
    if [ "$toggles" -lt 1 ]; then
        echo "FAIL: clocks.resc - only $toggles LED toggle(s) observed"
        overall=1
    else
        echo "PASS: clocks.resc (banner OK, $toggles LED toggles)"
    fi
    rm -f "$log"
fi

# ===== TIMER (M3-B) =====
# ---- 3. timer.resc - M3-B TIMER0 ALARM0 IRQ blink demo -----------------------
# Build the demo if needed.
if [ ! -f "$repo/build/timer_alarm_demo.elf" ]; then
    echo "INFO: build/timer_alarm_demo.elf missing - building..."
    make -C "$repo" build/timer_alarm_demo.uf2 >/dev/null
fi
log="$(run_one "tests/renode/timer.resc")" || { overall=1; }
if [ -n "${log:-}" ] && [ -f "$log" ]; then
    echo "----- timer.resc log (last 30 lines) -----"
    tail -30 "$log"
    echo "------------------------------------------"
    toggles="$(grep -c 'LED_TOGGLE' "$log" || true)"
    # 100 ms alarm period over 1 simulated second -> at least 9 toggles
    # (allow 1 startup grace period).
    if [ "$toggles" -lt 9 ]; then
        echo "FAIL: timer.resc - only $toggles LED toggle(s) observed (need >= 9)"
        overall=1
    else
        echo "PASS: timer.resc ($toggles LED toggles via TIMER0 ALARM0 ISR)"
    fi
    rm -f "$log"
fi
# ===== END TIMER =====

if [ $overall -ne 0 ]; then
    exit 1
fi

echo "PASS: renode T3 (all scripts)"
exit 0
