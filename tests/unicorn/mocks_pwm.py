# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""PWM mocks for the Unicorn T1 harness (M3-D).

The PWM peripheral has no async side-effects we have to model for the
firmware to make progress: writes land, reads return whatever was last
written.  We only ship register-trace helpers here:

    PWM_BASE       absolute base
    PWM_SLICE      lambda slice -> base+slice*0x14
    pwm_writes_to  filter sim.writes for an absolute address (any size)
    mock_pwm_counter(sim, slice, ticks_per_call)
        Optional helper that increments PWM CTR each time the firmware
        reads it.  Useful for testing CTR-reading code without having to
        run the actual 16-bit free-running counter.
"""

from __future__ import annotations

from typing import List, Optional

# Address constants - mirror include/pwm.inc
PWM_BASE = 0x400A8000
PWM_SLICE_STRIDE = 0x14
PWM_NUM_SLICES = 12

# Per-slice register offsets (relative to slice base)
PWM_CH_CSR = 0x00
PWM_CH_DIV = 0x04
PWM_CH_CTR = 0x08
PWM_CH_CC = 0x0C
PWM_CH_TOP = 0x10

# Global PWM registers (relative to PWM_BASE)
PWM_EN = 0xF0
PWM_INTR = 0xF4
PWM_INTE = 0xF8
PWM_INTF = 0xFC
PWM_INTS = 0x100

# Atomic alias offsets (RP2350 standard)
ATOMIC_RW = 0x0000
ATOMIC_XOR = 0x1000
ATOMIC_SET = 0x2000
ATOMIC_CLR = 0x3000


def pwm_slice_base(slice_n: int) -> int:
    """Absolute byte address of slice N's register block."""
    if not 0 <= slice_n < PWM_NUM_SLICES:
        raise ValueError(f"slice {slice_n} out of range [0, {PWM_NUM_SLICES})")
    return PWM_BASE + slice_n * PWM_SLICE_STRIDE


def pwm_writes_to(sim, addr: int, size: Optional[int] = None) -> List:
    """Return all sim.writes events targeting `addr`.

    If `size` is provided, also filters on access width (1/2/4 bytes).
    Useful for distinguishing the STRH path of pwm_set_chan_level from the
    STR path of pwm_set_both_levels - both touch CC but with different
    widths.
    """
    out = []
    for w in sim.writes:
        if w.addr != addr:
            continue
        if size is not None and w.size != size:
            continue
        out.append(w)
    return out


def mock_pwm_counter(sim, slice_n: int, ticks_per_call: int = 1) -> None:
    """Make CTR auto-increment on each read.

    Models the slice's 16-bit free-running counter without us actually
    advancing the divider.  `ticks_per_call` is added to a Python-side
    shadow on every read; the value wraps at 0x10000 to mirror silicon.

    Use this for code that does:
        bl  pwm_get_counter
        cmp r0, #threshold
        b...
    in a loop.  Without the mock, CTR is whatever the harness last left
    in memory (usually 0) and the loop never terminates.
    """
    base = pwm_slice_base(slice_n)
    addr = base + PWM_CH_CTR
    counter = [0]

    def cb(a: int, size: int) -> int:
        if a == addr:
            v = counter[0]
            counter[0] = (counter[0] + ticks_per_call) & 0xFFFF
            return v
        return None

    sim.on_read(addr, 4, cb)


def gpio_to_slice(pin: int) -> int:
    """RP2350 SDK macro: slice = ((pin >> 1) & 7) | ((pin >> 4) & 8)."""
    return ((pin >> 1) & 7) | ((pin >> 4) & 8)


def gpio_to_chan(pin: int) -> int:
    """A=0 (even pins), B=1 (odd pins)."""
    return pin & 1
