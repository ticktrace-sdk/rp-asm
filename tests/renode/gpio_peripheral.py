# =============================================================================
# tests/renode/gpio_peripheral.py - permissive RP2350 GPIO peripheral.
#
# Renode's `Python.PythonPeripheral` lets us plug a small inline script into
# any address window.  This file provides the *body* of that script for
# IO_BANK0, PADS_BANK0, and the SIO GPIO sub-window.  Whoever wires it into
# a .repl picks the address.
#
# Two ways to use it:
#
# 1. Embedded in a .repl (preferred for production tests):
#
#        gpio_io_bank0: Python.PythonPeripheral @ sysbus 0x40028000
#            size: 0x4000
#            initable: true
#            script: '@tests/renode/gpio_peripheral.py'
#
#    The script reads `request.IsRead / IsWrite / Offset / Value` and
#    decodes the alias window into a human-readable log line.
#
# 2. Standalone helper for translating a captured (addr, value) pair into
#    a trace line.  Useful for unit-testing the format without booting
#    Renode:
#
#        from gpio_peripheral import describe
#        print(describe(0xD0000028, 0x02000000, "Write"))
#        # -> "SIO GPIO25 OUT_XOR <- 0x02000000"
#
# The peripheral is permissive: every write is acked, every read returns 0
# (callers that need a real GPIO_IN value should poke memory or extend
# this module).  All it does is log.
# =============================================================================

# ----- Address-map constants (cross-checked against include/rp2350.inc) -----
IO_BANK0_BASE   = 0x40028000
PADS_BANK0_BASE = 0x40038000
SIO_BASE        = 0xD0000000

ATOMIC_XOR = 0x1000
ATOMIC_SET = 0x2000
ATOMIC_CLR = 0x3000

GPIO_FUNC_NAMES = {
    0:  "XIP",  1:  "SPI",  2:  "UART", 3:  "I2C",
    4:  "PWM",  5:  "SIO",  6:  "PIO0", 7:  "PIO1",
    8:  "PIO2", 9:  "GPCK", 10: "USB",  11: "UART_AUX",
    31: "NULL",
}

SIO_OFFSETS = {
    0x010: "OUT",       0x018: "OUT_SET",  0x020: "OUT_CLR",  0x028: "OUT_XOR",
    0x030: "OE",        0x038: "OE_SET",   0x040: "OE_CLR",   0x048: "OE_XOR",
    0x050: "HI_OUT",    0x058: "HI_OUT_SET", 0x060: "HI_OUT_CLR",
    0x068: "HI_OUT_XOR",
    0x070: "HI_OE",     0x078: "HI_OE_SET", 0x080: "HI_OE_CLR",
    0x088: "HI_OE_XOR",
    0x004: "GPIO_IN",   0x008: "GPIO_HI_IN",
}

ALIAS_NAMES = {0x0000: "RW", ATOMIC_XOR: "XOR", ATOMIC_SET: "SET",
               ATOMIC_CLR: "CLR"}


def _bits_set(value):
    """Return the list of bit positions set in `value`."""
    out = []
    v = value & 0xFFFFFFFF
    pos = 0
    while v:
        if v & 1:
            out.append(pos)
        v >>= 1
        pos += 1
    return out


def describe_io_bank0(offset, value, op):
    """Decode an IO_BANK0 access. offset is relative to IO_BANK0_BASE."""
    alias = offset & 0x3000
    base = offset & 0xFFF
    alias_str = ALIAS_NAMES.get(alias, f"?{alias:x}")
    # Per-GPIO STATUS / CTRL block: 8 bytes, 0..47 -> base 0..0x17F
    if base < 0x180:
        pin = base // 8
        sub = base & 4
        if sub == 0:
            kind = f"GPIO{pin}.STATUS"
        else:
            kind = f"GPIO{pin}.CTRL"
            if op == "Write":
                func = value & 0x1F
                fname = GPIO_FUNC_NAMES.get(func, str(func))
                return f"IO_BANK0 {kind} [{alias_str}] {op} func={fname}"
        return f"IO_BANK0 {kind} [{alias_str}] {op} <- 0x{value:08X}"
    # IRQ register array
    if 0x230 <= base < 0x320:
        # Each subarray: 6 regs * 4B = 0x18 bytes; arrays at INTR(0x230),
        # PROC0_INTE(0x248), INTF(0x260), INTS(0x278), PROC1_*(0x290..),
        # DORMANT_WAKE_*(0x2D8..).
        return (f"IO_BANK0 IRQ@+0x{base:03X} [{alias_str}] {op} <- "
                f"0x{value:08X}")
    return f"IO_BANK0 +0x{base:03X} [{alias_str}] {op} <- 0x{value:08X}"


def describe_pads_bank0(offset, value, op):
    alias = offset & 0x3000
    base = offset & 0xFFF
    alias_str = ALIAS_NAMES.get(alias, f"?{alias:x}")
    if base == 0:
        return f"PADS_BANK0 VOLTAGE_SELECT [{alias_str}] {op} <- 0x{value:X}"
    pin = (base - 4) // 4
    bits = []
    if value & (1 << 8): bits.append("ISO")
    if value & (1 << 7): bits.append("OD")
    if value & (1 << 6): bits.append("IE")
    if value & (1 << 3): bits.append("PUE")
    if value & (1 << 2): bits.append("PDE")
    if value & (1 << 1): bits.append("SCHMITT")
    if value & (1 << 0): bits.append("SLEWFAST")
    drv = (value >> 4) & 3
    bits_str = "|".join(bits) if bits else "0"
    return (f"PADS_BANK0 GPIO{pin} [{alias_str}] {op} <- 0x{value:X} "
            f"(bits={bits_str} drive={drv})")


def describe_sio(offset, value, op):
    name = SIO_OFFSETS.get(offset, f"+0x{offset:X}")
    pins = _bits_set(value)
    pins_str = ",".join(f"GP{p}" for p in pins) if pins else "(none)"
    return f"SIO {name} {op} <- 0x{value:08X} [{pins_str}]"


def describe(addr, value, op):
    """Top-level dispatch.  `addr` is absolute, `op` is 'Read' or 'Write'."""
    if PADS_BANK0_BASE <= addr < PADS_BANK0_BASE + 0x4000:
        return describe_pads_bank0(addr - PADS_BANK0_BASE, value, op)
    if IO_BANK0_BASE <= addr < IO_BANK0_BASE + 0x4000:
        return describe_io_bank0(addr - IO_BANK0_BASE, value, op)
    if SIO_BASE <= addr < SIO_BASE + 0x10000:
        return describe_sio(addr - SIO_BASE, value, op)
    return f"GPIO?? {addr:#X} {op} <- 0x{value:08X}"


# ----- PythonPeripheral entry point -----------------------------------------
# When Renode uses this file as a peripheral script, it pre-defines
# `request` (the bus access object) and a `cpu` reference.  We honour
# both Read and Write transactions and just log + permit them.
#
# This block is INACTIVE under plain `python3 gpio_peripheral.py` import
# (no `request` symbol in scope).
try:
    request  # noqa: F821 - injected by Renode at script-execution time
except NameError:
    pass
else:
    # Renode invokes the script per-access.  We need to special-case Init.
    if request.IsInit:
        # No state to initialise; logging is fire-and-forget.
        pass
    elif request.IsWrite:
        addr = request.Offset
        # We don't know our own base address from inside the script; the
        # operator is expected to have set `peripheral_base` ahead of time
        # via `machine.SystemBus.SetCustomVariable("peripheral_base", X)`.
        # Failing that, we log the offset alone.
        line = describe(int(addr), int(request.Value) & 0xFFFFFFFF, "Write")
        cpu.InfoLog(line)  # noqa: F821 - injected by Renode
    elif request.IsRead:
        request.Value = 0


# ----- Self-test ------------------------------------------------------------
if __name__ == "__main__":
    samples = [
        (0xD0000028, 0x02000000, "Write"),
        (0xD0000018, 0x00800000, "Write"),
        (0x40028004 + 25 * 8, 5, "Write"),                 # CTRL pin 25
        (0x40038000 + 0x3000 + 4 + 25 * 4, 0x180, "Write"),  # PAD CLR pin25
    ]
    for addr, value, op in samples:
        print(describe(addr, value, op))
