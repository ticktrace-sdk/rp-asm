# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

# =============================================================================
# tests/renode/pwm_peripheral.py - Python.PythonPeripheral script for the
# RP2350 PWM block (M3-D).
#
# Loaded into Renode via `tests/renode/rp2350.repl` (PWM trailer block).
# Models the per-slice CSR / DIV / CC / TOP plus the global EN / INTR / INTE
# registers.  Atomic alias windows (+0x1000 XOR / +0x2000 SET / +0x3000 CLR)
# are covered by sizing the region at 0x4000 and decoding the alias offset.
#
# On EN-bit transitions we log a one-line message so test scripts can grep:
#   "PWM slice N enabled" / "PWM slice N disabled".  We also count the total
# number of CC writes so the runner can prove the fade demo is animating
# (`grep -c PWM_CC_WRITE`).
#
# This file's contents are inlined inside rp2350.repl's PWM trailer block.
# Keep changes here in sync with that block.
# =============================================================================

if request.IsInit:
    state = {
        'csr':  [0]*12,
        'div':  [0]*12,
        'ctr':  [0]*12,
        'cc':   [0]*12,
        'top':  [0]*12,
        'en':   0,
        'intr': 0,
        'inte': 0,
        'intf': 0,
    }

elif request.IsRead:
    off = request.Offset & 0xFFF
    if off < 12 * 0x14:
        s = off // 0x14
        sub = off % 0x14
        if sub == 0x00:
            request.Value = state['csr'][s]
        elif sub == 0x04:
            request.Value = state['div'][s]
        elif sub == 0x08:
            request.Value = state['ctr'][s]
        elif sub == 0x0C:
            request.Value = state['cc'][s]
        elif sub == 0x10:
            request.Value = state['top'][s]
        else:
            request.Value = 0
    elif off == 0xF0:
        request.Value = state['en']
    elif off == 0xF4:
        request.Value = state['intr']
    elif off == 0xF8:
        request.Value = state['inte']
    elif off == 0xFC:
        request.Value = state['intf']
    elif off == 0x100:
        request.Value = state['intr'] & state['inte']
    else:
        request.Value = 0

elif request.IsWrite:
    off_full = request.Offset
    off = off_full & 0xFFF
    alias = off_full & 0x3000
    val = request.Value & 0xFFFFFFFF

    # Helper: compute alias result.  Inlined as expressions to avoid def
    # scoping quirks inside Renode's Python host.
    if off < 12 * 0x14:
        s = off // 0x14
        sub = off % 0x14
        if sub == 0x00:
            old = state['csr'][s]
            if alias == 0x0000: nv = val
            elif alias == 0x1000: nv = (old ^ val) & 0xFFFFFFFF
            elif alias == 0x2000: nv = (old | val) & 0xFFFFFFFF
            else: nv = old & ((~val) & 0xFFFFFFFF)
            state['csr'][s] = nv
        elif sub == 0x04:
            old = state['div'][s]
            if alias == 0x0000: nv = val
            elif alias == 0x1000: nv = (old ^ val) & 0xFFFFFFFF
            elif alias == 0x2000: nv = (old | val) & 0xFFFFFFFF
            else: nv = old & ((~val) & 0xFFFFFFFF)
            state['div'][s] = nv
        elif sub == 0x08:
            old = state['ctr'][s]
            if alias == 0x0000: nv = val
            elif alias == 0x1000: nv = (old ^ val) & 0xFFFFFFFF
            elif alias == 0x2000: nv = (old | val) & 0xFFFFFFFF
            else: nv = old & ((~val) & 0xFFFFFFFF)
            state['ctr'][s] = nv & 0xFFFF
        elif sub == 0x0C:
            old = state['cc'][s]
            if request.Length == 2:
                # 16-bit STRH to channel A half (CC + 0)
                nv = (old & 0xFFFF0000) | (val & 0xFFFF)
                state['cc'][s] = nv
                self.Log(LogLevel.Info,
                    'PWM_CC_WRITE slice={0} cc=0x{1:08X} (chA STRH)'.format(s, nv))
            else:
                if alias == 0x0000: nv = val
                elif alias == 0x1000: nv = (old ^ val) & 0xFFFFFFFF
                elif alias == 0x2000: nv = (old | val) & 0xFFFFFFFF
                else: nv = old & ((~val) & 0xFFFFFFFF)
                state['cc'][s] = nv
                self.Log(LogLevel.Info,
                    'PWM_CC_WRITE slice={0} cc=0x{1:08X}'.format(s, nv))
        elif sub == 0x0E:
            # 16-bit STRH to channel B half (CC + 2)
            old = state['cc'][s]
            nv = (old & 0x0000FFFF) | ((val & 0xFFFF) << 16)
            state['cc'][s] = nv
            self.Log(LogLevel.Info,
                'PWM_CC_WRITE slice={0} cc=0x{1:08X} (chB STRH)'.format(s, nv))
        elif sub == 0x10:
            old = state['top'][s]
            if alias == 0x0000: nv = val
            elif alias == 0x1000: nv = (old ^ val) & 0xFFFFFFFF
            elif alias == 0x2000: nv = (old | val) & 0xFFFFFFFF
            else: nv = old & ((~val) & 0xFFFFFFFF)
            state['top'][s] = nv & 0xFFFF
    elif off == 0xF0:
        old = state['en']
        if alias == 0x0000: nv = val
        elif alias == 0x1000: nv = (old ^ val) & 0xFFFFFFFF
        elif alias == 0x2000: nv = (old | val) & 0xFFFFFFFF
        else: nv = old & ((~val) & 0xFFFFFFFF)
        state['en'] = nv
        rose = (~old) & nv & 0xFFFFFFFF
        fell = old & ((~nv) & 0xFFFFFFFF)
        for sl in range(12):
            bit = 1 << sl
            if rose & bit:
                self.Log(LogLevel.Info,
                    'PWM slice {0} enabled (DIV=0x{1:08X} TOP=0x{2:04X} CC=0x{3:08X})'
                    .format(sl, state['div'][sl], state['top'][sl], state['cc'][sl]))
            if fell & bit:
                self.Log(LogLevel.Info, 'PWM slice {0} disabled'.format(sl))
    elif off == 0xF4:
        # write-1-to-clear on plain alias; SET/CLR/XOR pass through
        if alias == 0x0000:
            state['intr'] = state['intr'] & ((~val) & 0xFFFFFFFF)
        elif alias == 0x1000:
            state['intr'] = (state['intr'] ^ val) & 0xFFFFFFFF
        elif alias == 0x2000:
            state['intr'] = (state['intr'] | val) & 0xFFFFFFFF
        else:
            state['intr'] = state['intr'] & ((~val) & 0xFFFFFFFF)
    elif off == 0xF8:
        old = state['inte']
        if alias == 0x0000: state['inte'] = val
        elif alias == 0x1000: state['inte'] = (old ^ val) & 0xFFFFFFFF
        elif alias == 0x2000: state['inte'] = (old | val) & 0xFFFFFFFF
        else: state['inte'] = old & ((~val) & 0xFFFFFFFF)
    elif off == 0xFC:
        old = state['intf']
        if alias == 0x0000: state['intf'] = val
        elif alias == 0x1000: state['intf'] = (old ^ val) & 0xFFFFFFFF
        elif alias == 0x2000: state['intf'] = (old | val) & 0xFFFFFFFF
        else: state['intf'] = old & ((~val) & 0xFFFFFFFF)
