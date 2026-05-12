"""tests/renode/timer_peripheral.py - reference implementation of the TIMER0
TIMERAWL counter for Renode integration tests (M3-B).

This file is read by `tests/renode/timer.resc` and embedded into a
PythonPeripheral via LoadPlatformDescriptionFromString, so the body MUST be
self-contained Python code (no imports beyond what Renode's IronPython
runtime provides).

Behaviour modelled:
  * 32-bit free-running counter at 1 MHz simulated wall-clock rate
  * Read of TIMER_BASE + 0x28 (TIMERAWL) returns the current value
  * Read of TIMER_BASE + 0x0c (TIMELR) latches and returns the low half
  * Read of TIMER_BASE + 0x08 (TIMEHR) returns the previously-latched high
  * Writes to TIMER_BASE + 0x10..0x1c (ALARMn) auto-arm in ARMED
  * Writes to TIMER_BASE + 0x20 (ARMED) are W1C
  * Writes to TIMER_BASE + 0x34 (INTR) are W1C
  * Anything else is dropped silently and returns 0 on read

We don't try to fire the alarm IRQs because Renode wires up its own NVIC
and we'd need to plumb GPIO connections; the .resc test instead measures
LED toggles via SIO bus monitoring (same approach as M1/M2 tests).
"""

# This is a *script body* string consumed by Renode's PythonPeripheral.  We
# expose it as a module-level constant so the .resc can read it via
# `python.execute`.  It is intentionally *not* a Python module that gets
# imported normally - Renode's runtime is IronPython 2.x.

TIMER_PERIPHERAL_SCRIPT = '''
if request.IsInit:
    # Wall-clock-driven 32-bit microsecond counter.  We cheat: instead of
    # running at literal 1 MHz, we increment by 1 on every read.  This
    # gives the firmware a monotonic tick and keeps the Renode VM cheap.
    state = {"counter": 0, "latched_hi": 0, "armed": 0, "intr": 0}
elif request.IsRead:
    off = request.Offset & 0xFFF
    if off == 0x28:                 # TIMERAWL
        state["counter"] = (state["counter"] + 1) & 0xFFFFFFFF
        request.Value = state["counter"]
    elif off == 0x24:               # TIMERAWH
        request.Value = 0
    elif off == 0x0c:               # TIMELR (latches HI)
        state["counter"] = (state["counter"] + 1) & 0xFFFFFFFF
        state["latched_hi"] = 0
        request.Value = state["counter"]
    elif off == 0x08:               # TIMEHR
        request.Value = state["latched_hi"]
    elif off == 0x20:               # ARMED
        request.Value = state["armed"]
    elif off == 0x34:               # INTR
        request.Value = state["intr"]
    else:
        request.Value = 0
elif request.IsWrite:
    off = request.Offset & 0xFFF
    val = request.Value & 0xFFFFFFFF
    if 0x10 <= off < 0x20:          # ALARM0..3
        n = (off - 0x10) >> 2
        state["armed"] |= (1 << n)
    elif off == 0x20:               # ARMED W1C
        state["armed"] &= (~val) & 0xF
    elif off == 0x34:               # INTR W1C
        state["intr"] &= (~val) & 0xF
'''
