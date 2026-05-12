"""Timer mocks for the Unicorn harness (M3-B).

The TIMER0 / TIMER1 peripherals are 64-bit free-running microsecond counters
clocked off the TICKS sub-block.  Unicorn doesn't model anything time-related,
so these helpers fake it:

  * mock_timer_running(sim)
        Every read of TIMER<x>_BASE + TIMERAWL returns a counter that
        increments by `ticks_per_call` per access.  Useful for delay loops.

  * mock_timer_64(sim)
        Same as above but also synthesises the latched TIMELR/TIMEHR pair so
        time_us_64() returns sensible values.

  * fast_forward(sim, us)
        Bump the synthesised counter by `us` microseconds.  Intended to be
        called from a UC_HOOK_CODE breakpoint to short-circuit a delay_us
        loop in tests.

These helpers are intentionally peripheral-side: the firmware logic isn't
modified, the harness just lies about TIMERAWL.
"""

from __future__ import annotations

from typing import Optional


# Timer register layout (mirror include/timer.inc)
TIMER0_BASE = 0x400b0000
TIMER1_BASE = 0x400b8000

TIMER_TIMEHW   = 0x00
TIMER_TIMELW   = 0x04
TIMER_TIMEHR   = 0x08
TIMER_TIMELR   = 0x0c
TIMER_ALARM0   = 0x10
TIMER_ARMED    = 0x20
TIMER_TIMERAWH = 0x24
TIMER_TIMERAWL = 0x28
TIMER_INTR     = 0x34


class _TimerState:
    """Per-timer counter shared between read/write hooks."""

    def __init__(self, ticks_per_call: int = 1):
        self.counter: int = 0
        self.ticks_per_call: int = ticks_per_call
        self.latched_hi: int = 0
        self.armed: int = 0


def mock_timer_running(sim, ticks_per_call: int = 1, base: int = TIMER0_BASE):
    """Make TIMERAWL on `base` advance by `ticks_per_call` per read.

    Returns the _TimerState so the caller can `fast_forward` it.
    """
    state = _TimerState(ticks_per_call)

    def read_cb(addr: int, size: int):
        offset = (addr - base) & 0xFFF
        if offset == TIMER_TIMERAWL:
            state.counter = (state.counter + state.ticks_per_call) & 0xFFFFFFFF
            return state.counter
        if offset == TIMER_TIMERAWH:
            return (state.counter >> 32) & 0xFFFFFFFF
        if offset == TIMER_TIMELR:
            # Latch HI for the subsequent TIMEHR read
            state.counter = (state.counter + state.ticks_per_call) & 0xFFFFFFFF
            state.latched_hi = (state.counter >> 32) & 0xFFFFFFFF
            return state.counter & 0xFFFFFFFF
        if offset == TIMER_TIMEHR:
            return state.latched_hi
        if offset == TIMER_ARMED:
            return state.armed
        return None

    def write_cb(addr: int, value: int, size: int):
        offset = (addr - base) & 0xFFF
        # ALARMn auto-arms (datasheet sec 12.8)
        if TIMER_ALARM0 <= offset < TIMER_ALARM0 + 16:
            alarm_idx = (offset - TIMER_ALARM0) >> 2
            state.armed |= (1 << alarm_idx)
        # ARMED is RW1C
        elif offset == TIMER_ARMED:
            state.armed &= ~(value & 0xF)

    sim.on_read(base, 0x4000, read_cb)
    sim.on_write(base, 0x4000, write_cb)
    return state


def fast_forward(state: _TimerState, us: int) -> None:
    """Bump the mock counter by `us` microseconds."""
    state.counter = (state.counter + us) & 0xFFFFFFFF
