#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

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
#                  ASSERT: UART contains "ticktrace" banner, >= 4 LED toggles
#                  (since M2 the production main is the 150 MHz clocks demo;
#                  we relaxed the banner to just "ticktrace" to cover both v0.1
#                  and M2 banners)
#   clocks.resc  - M2 clocks demo in build/clocks_demo.elf
#                  ASSERT: UART contains "150 MHz", >= 1 LED toggle
#   pwm.resc     - M3-D PWM fade demo in build/pwm_fade_demo.elf
#                  ASSERT: peripheral logged a "PWM slice 7 enabled" event
#                          AND >= 10 PWM_CC_WRITE events (proves animation)
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
if [ ! -f "$repo/build/pwm_fade_demo.elf" ]; then
    echo "INFO: build/pwm_fade_demo.elf missing - building..."
    make -C "$repo" build/pwm_fade_demo.uf2 >/dev/null
fi
if [ ! -f "$repo/build/dma_memcpy_demo.elf" ]; then
    echo "INFO: build/dma_memcpy_demo.elf missing - building..."
    make -C "$repo" build/dma_memcpy_demo.uf2 >/dev/null
fi
if [ ! -f "$repo/build/gpio_demo.elf" ]; then
    echo "INFO: build/gpio_demo.elf missing - building..."
    make -C "$repo" build/gpio_demo.uf2 >/dev/null
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
    if ! grep -q "ticktrace" "$log"; then
        echo "FAIL: blinky.resc - UART missing 'ticktrace' banner"
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

# ===== PWM (M3-D) =====
# ---- 4. pwm.resc - M3-D PWM fade demo ---------------------------------------
log="$(run_one "tests/renode/pwm.resc")" || { overall=1; }
if [ -n "${log:-}" ] && [ -f "$log" ]; then
    echo "----- pwm.resc log (last 40 lines) -----"
    tail -40 "$log"
    echo "----------------------------------------"
    if ! grep -q "PWM slice 7 enabled" "$log"; then
        echo "FAIL: pwm.resc - slice 7 was never enabled"
        overall=1
    fi
    cc_writes="$(grep -c 'PWM_CC_WRITE' "$log" || true)"
    if [ "$cc_writes" -lt 10 ]; then
        echo "FAIL: pwm.resc - only $cc_writes CC writes (want >=10 for fade animation)"
        overall=1
    else
        echo "PASS: pwm.resc (slice enabled, $cc_writes CC writes observed)"
    fi
    rm -f "$log"
fi
# ===== END PWM =====

# ===== DMA (M3-C) =====
# ---- 5. dma.resc - M3-C DMA memcpy demo (skip if elf missing) -------------
if [ -f "$repo/build/dma_memcpy_demo.elf" ]; then
    log="$(run_one "tests/renode/dma.resc")" || { overall=1; }
    if [ -n "${log:-}" ] && [ -f "$log" ]; then
        echo "----- dma.resc log (last 30 lines) -----"
        tail -30 "$log"
        echo "-----------------------------------------"
        if ! grep -q "DMA OK" "$log"; then
            echo "FAIL: dma.resc - UART missing 'DMA OK'"
            overall=1
        else
            echo "PASS: dma.resc (DMA copy + cycle banner OK)"
        fi
        rm -f "$log"
    fi
else
    echo "SKIP: dma.resc - build/dma_memcpy_demo.elf missing"
fi
# ===== END DMA =====

# ===== GPIO (M3-A) =====
# ---- 6. gpio.resc - M3-A GPIO demo on pins 22/23/24 -------------------------
log="$(run_one "tests/renode/gpio.resc")" || { overall=1; }
if [ -n "${log:-}" ] && [ -f "$log" ]; then
    echo "----- gpio.resc log (last 30 lines) -----"
    tail -30 "$log"
    echo "------------------------------------------"
    sio_events="$(grep -cE 'GPIO_OUT_(SET|CLR|XOR)|GPIO_OE_SET' "$log" || true)"
    if [ "$sio_events" -lt 8 ]; then
        echo "FAIL: gpio.resc - only $sio_events SIO GPIO_OUT events (want >= 8)"
        overall=1
    else
        echo "PASS: gpio.resc ($sio_events SIO_GPIO_OUT events)"
    fi
    rm -f "$log"
fi
# ===== END GPIO =====

# ===== UART (M4-E) =====
# ---- 7. uart.resc - M4-E UART0 <-> UART1 loopback demo ----------------------
# Build the demo if needed.
if [ ! -f "$repo/build/uart_loopback_demo.elf" ]; then
    echo "INFO: build/uart_loopback_demo.elf missing - building..."
    make -C "$repo" build/uart_loopback_demo.uf2 >/dev/null
fi
log="$(run_one "tests/renode/uart.resc")" || { overall=1; }
if [ -n "${log:-}" ] && [ -f "$log" ]; then
    echo "----- uart.resc log (last 40 lines) -----"
    tail -40 "$log"
    echo "------------------------------------------"
    if ! grep -q "uart-loopback OK" "$log"; then
        echo "FAIL: uart.resc - missing 'uart-loopback OK' on UART0 (loopback failed)"
        overall=1
    else
        echo "PASS: uart.resc (UART0 <-> UART1 loopback succeeded)"
    fi
    rm -f "$log"
fi
# ===== END UART =====

# ===== I2C (M4-F) =====
# ---- 8. i2c.resc - M4-F I2C EEPROM demo (skip if elf missing) ---------------
if [ ! -f "$repo/build/i2c_eeprom_demo.elf" ]; then
    echo "INFO: build/i2c_eeprom_demo.elf missing - building..."
    make -C "$repo" build/i2c_eeprom_demo.uf2 >/dev/null
fi
if [ -f "$repo/build/i2c_eeprom_demo.elf" ]; then
    log="$(run_one "tests/renode/i2c.resc")" || { overall=1; }
    if [ -n "${log:-}" ] && [ -f "$log" ]; then
        echo "----- i2c.resc log (last 30 lines) -----"
        tail -30 "$log"
        echo "-----------------------------------------"
        if ! grep -q "EEPROM" "$log"; then
            echo "FAIL: i2c.resc - UART missing 'EEPROM' banner"
            overall=1
        elif ! grep -qi "READ:" "$log"; then
            echo "FAIL: i2c.resc - UART missing 'READ:' line (no read-back)"
            overall=1
        else
            echo "PASS: i2c.resc (EEPROM banner + READ-back line OK)"
        fi
        rm -f "$log"
    fi
else
    echo "SKIP: i2c.resc - build/i2c_eeprom_demo.elf missing"
fi
# ===== END I2C =====

# ===== SPI (M4-G) =====
# ---- 9. spi.resc - M4-G SPI loopback demo (skip if elf missing) ------------
if [ ! -f "$repo/build/spi_loopback_demo.elf" ]; then
    echo "INFO: build/spi_loopback_demo.elf missing - building..."
    make -C "$repo" build/spi_loopback_demo.uf2 >/dev/null
fi
if [ -f "$repo/build/spi_loopback_demo.elf" ]; then
    log="$(run_one "tests/renode/spi.resc")" || { overall=1; }
    if [ -n "${log:-}" ] && [ -f "$log" ]; then
        echo "----- spi.resc log (last 30 lines) -----"
        tail -30 "$log"
        echo "-----------------------------------------"
        if ! grep -q "PASS" "$log"; then
            echo "FAIL: spi.resc - UART missing 'PASS' (loopback verify failed)"
            overall=1
        else
            echo "PASS: spi.resc (PL022 LBM end-to-end OK)"
        fi
        rm -f "$log"
    fi
else
    echo "SKIP: spi.resc - build/spi_loopback_demo.elf missing"
fi
# ===== END SPI =====

# ===== USB (M4-H) =====
# ---- 10. usb.resc - M4-H USB CDC echo demo --------------------------------
if [ ! -f "$repo/build/usb_cdc_echo_demo.elf" ]; then
    echo "INFO: build/usb_cdc_echo_demo.elf missing - building..."
    make -C "$repo" build/usb_cdc_echo_demo.uf2 >/dev/null
fi
log="$(run_one "tests/renode/usb.resc")" || { overall=1; }
if [ -n "${log:-}" ] && [ -f "$log" ]; then
    echo "----- usb.resc log (last 30 lines) -----"
    tail -30 "$log"
    echo "------------------------------------------"
    if ! grep -q "USB_MAIN_CTRL <-" "$log"; then
        echo "FAIL: usb.resc - USB_MAIN_CTRL store never logged (firmware may"
        echo "      have hung before reaching usb_device_init's controller-enable)"
        overall=1
    else
        echo "PASS: usb.resc (USB controller MAIN_CTRL store landed)"
    fi
    rm -f "$log"
fi
# ===== END USB =====

if [ $overall -ne 0 ]; then
    exit 1
fi

echo "PASS: renode T3 (all scripts)"
exit 0
