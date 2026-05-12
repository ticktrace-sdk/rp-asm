"""RP2350 DMA functional model for Renode (M3-C).

Loaded by tests/renode/rp2350.repl as the script payload of a
Python.PythonPeripheral instance.  Renode evaluates this file once per
sysbus access; the `request` magic global describes the in-flight access:

    request.IsInit  : peripheral construction; create per-instance state
    request.IsRead  : read access; populate `request.Value`
    request.IsWrite : write access; consume `request.Value`

Per-channel state we track:
  read, write, count, ctrl

Triggering offsets (CTRL_TRIG and the three TRIG aliases) cause a
synchronous byte-level copy from READ_ADDR to WRITE_ADDR via SystemBus.
BUSY (CTRL bit 26) is *always* read as 0 because the copy completes inside
the trigger write; this matches the harness's "fast-finish" mock and is a
faithful enough model of the hardware for our integration tests.

We also model:
  - INTR (W1C) and INTE0..3 (R/W) for IRQ aggregation
  - SNIFF_CTRL / SNIFF_DATA (R/W; CRC32 itself is NOT computed here - this
    is a stub.  The Unicorn harness covers the SNIFF_DATA register-level
    check; the integration test only verifies the CRC banner shape, not
    the value).
  - MULTI_CHAN_TRIGGER as an additional trigger path
  - CHAN_ABORT as a no-op that always reads back 0.

NB: this script is included verbatim by `script: '''...'''` in
rp2350.repl - the file form is here for human review and easier diff'ing.
The two MUST stay byte-identical (sans the docstring header); CI does NOT
detect drift.
"""

if request.IsInit:
    chan = [{"read": 0, "write": 0, "count": 0, "ctrl": 0} for _ in range(16)]
    sniff = {"ctrl": 0, "data": 0}
    irq = {"intr": 0, "inte": [0, 0, 0, 0]}
    # PythonPeripheral does not expose its parent Machine.  Resolve a
    # SystemBus reference indirectly via the EmulationManager singleton.
    # Single-machine assumption is fine for our tests.
    from Antmicro.Renode.Core import EmulationManager
    _emu = EmulationManager.Instance.CurrentEmulation
    _bus = list(_emu.Machines)[0].SystemBus
elif request.IsRead:
    off = request.Offset & 0xFFFF
    base = off & 0xFFF
    if base < 0x400:
        ch = base // 0x40
        sub = base % 0x40
        if sub in (0x0C, 0x10, 0x20, 0x30):
            request.Value = chan[ch]["ctrl"] & ~(1 << 26)
        elif sub == 0x00:
            request.Value = chan[ch]["read"]
        elif sub == 0x04:
            request.Value = chan[ch]["write"]
        elif sub == 0x08:
            request.Value = chan[ch]["count"]
        else:
            request.Value = 0
    elif base == 0x400:
        request.Value = irq["intr"]
    elif base in (0x404, 0x414, 0x424, 0x434):
        request.Value = irq["inte"][(base - 0x404) // 0x10]
    elif base == 0x434:
        request.Value = sniff["ctrl"]
    elif base == 0x438:
        request.Value = sniff["data"]
    elif base == 0x444:
        request.Value = 0
    elif base == 0x448:
        request.Value = 16
    else:
        request.Value = 0
elif request.IsWrite:
    off = request.Offset & 0xFFFF
    base = off & 0xFFF
    val = request.Value & 0xFFFFFFFF
    if base < 0x400:
        ch = base // 0x40
        sub = base % 0x40
        c = chan[ch]
        if sub in (0x00, 0x14, 0x28, 0x3C):
            c["read"] = val
        elif sub in (0x04, 0x18, 0x34, 0x2C):
            c["write"] = val
        elif sub in (0x08, 0x1C, 0x24, 0x38):
            c["count"] = val
        elif sub in (0x0C, 0x10, 0x20, 0x30):
            c["ctrl"] = val
        if sub in (0x0C, 0x1C, 0x2C, 0x3C):
            ds = (c["ctrl"] >> 2) & 0x3
            elt = {0: 1, 1: 2, 2: 4}.get(ds, 1)
            n = c["count"] * elt
            if n > 0 and c["read"] != 0 and c["write"] != 0:
                src = c["read"]
                dst = c["write"]
                for i in range(n):
                    b = _bus.ReadByte(src + i)
                    _bus.WriteByte(dst + i, b)
            if not (c["ctrl"] & (1 << 23)):
                irq["intr"] |= (1 << ch)
    elif base == 0x400:
        irq["intr"] &= ~val
    elif base in (0x404, 0x414, 0x424, 0x434):
        irq["inte"][(base - 0x404) // 0x10] = val
    elif base == 0x430:
        for ch in range(16):
            if val & (1 << ch):
                c = chan[ch]
                ds = (c["ctrl"] >> 2) & 0x3
                elt = {0: 1, 1: 2, 2: 4}.get(ds, 1)
                n = c["count"] * elt
                if n > 0 and c["read"] != 0 and c["write"] != 0:
                    src = c["read"]
                    dst = c["write"]
                    for i in range(n):
                        b = _bus.ReadByte(src + i)
                        _bus.WriteByte(dst + i, b)
                if not (c["ctrl"] & (1 << 23)):
                    irq["intr"] |= (1 << ch)
    elif base == 0x434:
        sniff["ctrl"] = val
    elif base == 0x438:
        sniff["data"] = val
    elif base == 0x444:
        pass
