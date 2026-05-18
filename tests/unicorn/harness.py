# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""RP2350 Unicorn-Engine simulation harness.

Tier 1 of the ticktrace test strategy: cycle-counted, deterministic execution
of an ELF (or flat binary) with full visibility into every MMIO transaction.
This is where we lock the *contract* between the assembly source and the
peripherals - what the firmware writes, in what order, with what value.

Why Unicorn (vs. QEMU/Renode):
  - host-process speed (~50 us per test)
  - Python hooks on every MMIO read/write at 1-byte granularity
  - no Cortex-M peripheral model = we control exactly what the bus reports

Limitations:
  - Unicorn is pure Cortex-M instruction emulation; it has no SysTick, no
    NVIC, no SCB peripherals beyond what we mock
  - Floating-point and DSP-extension behaviour is best-effort
  - timing is instruction-count, not real cycles

Typical test shape:
    sim = RP2350Sim()
    sim.load_elf("build/blinky.elf")
    sim.mock_resets_done()                        # peripheral acks
    sim.run_until_pc(sim.symbol("main"))
    assert sim.writes[0] == (RESETS_BASE+0x3000, (1<<6)|(1<<9)|(1<<26))
"""

from __future__ import annotations

import os
import struct
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

from unicorn import (
    Uc,
    UC_ARCH_ARM,
    UC_MODE_THUMB,
    UC_MODE_MCLASS,
    UC_HOOK_MEM_READ,
    UC_HOOK_MEM_WRITE,
    UC_HOOK_CODE,
    UC_PROT_ALL,
    UC_PROT_READ,
    UC_PROT_WRITE,
)
from unicorn.arm_const import UC_ARM_REG_SP, UC_ARM_REG_PC, UC_ARM_REG_LR

try:
    from elftools.elf.elffile import ELFFile
    _HAVE_PYELF = True
except ImportError:  # pragma: no cover - import-guard
    _HAVE_PYELF = False


# RP2350 memory map - keep in sync with include/rp2350.inc
SRAM_BASE = 0x20000000
SRAM_SIZE = 512 * 1024

# All APB peripherals live in 0x40000000-0x4FFFFFFF.  We map one big page so
# any unmapped store traps via our write hook with a synthetic "0" read.
APB_BASE = 0x40000000
APB_SIZE = 0x10000000

# SIO is special: 0xD0000000, M33-local, single-cycle.
SIO_BASE = 0xD0000000
SIO_SIZE = 0x00010000

# Arm v8-M System Control space
PPB_BASE = 0xE0000000
PPB_SIZE = 0x00100000


@dataclass
class MmioEvent:
    """One bus transaction observed by the harness.

    pc:        instruction PC at the time of the access
    addr:      absolute bus address
    size:      access width in bytes (1/2/4)
    value:     written value (writes only) - reads carry the value returned
    is_write:  True for writes
    """

    pc: int
    addr: int
    size: int
    value: int
    is_write: bool

    def __repr__(self) -> str:  # pragma: no cover - cosmetic
        d = "W" if self.is_write else "R"
        return f"<{d} pc={self.pc:#010x} addr={self.addr:#010x} val={self.value:#010x} sz={self.size}>"


class RP2350Sim:
    """Bare-bones RP2350 simulator built on Unicorn-Engine.

    The harness intentionally does *not* model the boot ROM.  Tests load an
    image at SRAM_BASE and the constructor reads the first two vector slots
    for SP/PC, exactly as the bootrom would.
    """

    def __init__(self) -> None:
        self.uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)

        # Map the RAM the firmware actually executes from
        self.uc.mem_map(SRAM_BASE, SRAM_SIZE, UC_PROT_ALL)

        # Map peripheral windows.  We default to all-zero on read, which is a
        # conservative approximation of "this register hasn't been mocked".
        self.uc.mem_map(APB_BASE, APB_SIZE, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(SIO_BASE, SIO_SIZE, UC_PROT_READ | UC_PROT_WRITE)
        self.uc.mem_map(PPB_BASE, PPB_SIZE, UC_PROT_READ | UC_PROT_WRITE)

        # All MMIO writes land here in order; tests assert against this list.
        self.writes: List[MmioEvent] = []
        self.reads: List[MmioEvent] = []

        # User-installed callbacks: (base, size) -> fn(addr, value, size)
        self._write_hooks: List[Tuple[int, int, Callable[[int, int, int], None]]] = []
        self._read_hooks: List[Tuple[int, int, Callable[[int, int], int]]] = []

        # Optional per-PC hooks for breakpoints / coverage
        self._pc_hooks: Dict[int, Callable[["RP2350Sim"], None]] = {}

        # Symbol table populated when an ELF is loaded
        self.symbols: Dict[str, int] = {}

        # Instruction count for run_steps cap and last-resort termination
        self._executed = 0
        self._stop_at_pc: Optional[int] = None
        self._stop_after_steps: Optional[int] = None
        self._stopped_reason: Optional[str] = None

        # Wire up the bus hooks once.  We dispatch to per-region callbacks
        # from inside _on_write / _on_read so that test code never has to
        # touch Unicorn directly.
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self._on_write,
                         begin=APB_BASE, end=APB_BASE + APB_SIZE - 1)
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self._on_write,
                         begin=SIO_BASE, end=SIO_BASE + SIO_SIZE - 1)
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self._on_write,
                         begin=PPB_BASE, end=PPB_BASE + PPB_SIZE - 1)
        self.uc.hook_add(UC_HOOK_MEM_READ, self._on_read,
                         begin=APB_BASE, end=APB_BASE + APB_SIZE - 1)
        self.uc.hook_add(UC_HOOK_MEM_READ, self._on_read,
                         begin=SIO_BASE, end=SIO_BASE + SIO_SIZE - 1)
        self.uc.hook_add(UC_HOOK_MEM_READ, self._on_read,
                         begin=PPB_BASE, end=PPB_BASE + PPB_SIZE - 1)
        self.uc.hook_add(UC_HOOK_CODE, self._on_code)

    # ---------------------------------------------------------------- loaders

    # 32-bit Thumb instructions that real RP2350 silicon needs in _reset
    # but Unicorn (no Cortex-M33 RCP coprocessor / MSPLIM modelling) faults
    # on.  We NOP them out at load time so T1 keeps emulating cleanly while
    # startup.S stays correct for hardware.  Bytes are little-endian as they
    # appear in the flat .bin.
    _HW_ONLY_INSNS = (
        b"\x30\xee\x10\xf7",   # mrc   p7, #1, APSR_nzcv, c0, c0, #0
        b"\x40\xec\x80\x07",   # mcrr  p7, #8, r0, r0, c0
        b"\x40\xec\x81\x07",   # mcrr  p7, #8, r0, r0, c1
        b"\x80\xf3\x0a\x88",   # msr   MSPLIM, r0
    )
    _DOUBLE_NOP = b"\x00\xbf\x00\xbf"

    def _patch_hw_only_insns(self, base: int, blob: bytes) -> bytes:
        """Replace M33 RCP / MSPLIM instructions with NOPs in `blob`."""
        out = bytearray(blob)
        for needle in self._HW_ONLY_INSNS:
            off = 0
            while True:
                idx = out.find(needle, off)
                if idx < 0:
                    break
                out[idx:idx + 4] = self._DOUBLE_NOP
                off = idx + 4
        return bytes(out)

    def load_bin(self, path: str, base: int = SRAM_BASE) -> None:
        """Load a flat binary at `base`.  Reads vec[0]/vec[1] for SP/PC."""
        with open(path, "rb") as f:
            blob = f.read()
        if base + len(blob) > SRAM_BASE + SRAM_SIZE:
            raise ValueError(f"binary {path} ({len(blob)} B) overruns SRAM")
        self.uc.mem_write(base, self._patch_hw_only_insns(base, blob))
        self._set_initial_sp_pc(base)

    def load_elf(self, path: str) -> None:
        """Load each PT_LOAD segment to its physical address.

        Falls back to load_bin() if pyelftools isn't installed - in that
        case we expect a sibling `.bin` next to the `.elf`.
        """
        if not _HAVE_PYELF:
            bin_path = os.path.splitext(path)[0] + ".bin"
            if not os.path.exists(bin_path):
                raise RuntimeError(
                    "pyelftools not installed and no .bin sibling found; "
                    f"expected {bin_path}")
            return self.load_bin(bin_path, SRAM_BASE)

        with open(path, "rb") as f:
            elf = ELFFile(f)
            # Collect symbols for run_until_symbol() / debug
            for section in elf.iter_sections():
                if section.header["sh_type"] != "SHT_SYMTAB":
                    continue
                for sym in section.iter_symbols():
                    if sym.name and sym["st_value"]:
                        # Strip the Thumb bit so callers can compare against a
                        # raw PC observed from Unicorn (which won't have it).
                        self.symbols[sym.name] = sym["st_value"] & ~1

            for seg in elf.iter_segments():
                if seg.header["p_type"] != "PT_LOAD":
                    continue
                pa = seg.header["p_paddr"]
                data = seg.data()
                if not data:
                    continue
                self.uc.mem_write(pa, self._patch_hw_only_insns(pa, data))

        # Vector table must live at the start of SRAM in our linker layout
        self._set_initial_sp_pc(SRAM_BASE)

    def _set_initial_sp_pc(self, vt_base: int) -> None:
        sp = struct.unpack("<I", self.uc.mem_read(vt_base, 4))[0]
        pc = struct.unpack("<I", self.uc.mem_read(vt_base + 4, 4))[0]
        self.uc.reg_write(UC_ARM_REG_SP, sp)
        # Strip Thumb bit; Unicorn already runs in MCLASS|THUMB
        self._initial_pc = pc & ~1
        self.uc.reg_write(UC_ARM_REG_PC, self._initial_pc)

    # ----------------------------------------------------------------- mocking

    def on_write(self, base: int, size: int,
                 fn: Callable[[int, int, int], None]) -> None:
        """Register a write callback over [base, base+size).

        fn(addr, value, size) is invoked *after* the value is written to
        Unicorn's memory.  Use it to model side effects (e.g. setting
        RESETS_RESET_DONE to mirror RESETS_RESET).
        """
        self._write_hooks.append((base, size, fn))

    def on_read(self, base: int, size: int,
                fn: Callable[[int, int], int]) -> None:
        """Register a read callback over [base, base+size).

        fn(addr, size) -> value.  The returned value is *patched* into
        Unicorn's mapped memory just before the access completes, so the
        firmware sees the synthesised reading.
        """
        self._read_hooks.append((base, size, fn))

    def poke32(self, addr: int, value: int) -> None:
        """Convenience: pre-load a 32-bit MMIO register."""
        self.uc.mem_write(addr, struct.pack("<I", value & 0xFFFFFFFF))

    def peek32(self, addr: int) -> int:
        return struct.unpack("<I", self.uc.mem_read(addr, 4))[0]

    def mock_resets_done(self) -> None:
        """Auto-mirror writes to RESETS_RESET into RESETS_RESET_DONE.

        The v0.1 startup spins on `(RESET_DONE & mask) == mask` after CLR'ing
        bits in RESET_RESET.  Without this mock, the firmware never makes
        progress.  We model the hardware semantics: RESET_DONE = ~RESET.
        """
        RESETS_BASE = 0x40020000
        # Pre-seed: pretend everything is currently held in reset.
        self.poke32(RESETS_BASE + 0x00, 0xFFFFFFFF)  # RESET
        self.poke32(RESETS_BASE + 0x08, 0x00000000)  # RESET_DONE

        def cb(addr: int, value: int, size: int) -> None:
            offset = addr - RESETS_BASE
            # ATOMIC_CLR alias on RESET (offset 0x3000) - a write of `value`
            # clears those bits in RESET, which means the corresponding
            # peripheral has come out of reset.
            if offset == 0x3000:
                cur = self.peek32(RESETS_BASE + 0x00)
                cur &= ~value
                self.poke32(RESETS_BASE + 0x00, cur)
                self.poke32(RESETS_BASE + 0x08, ~cur & 0xFFFFFFFF)
            elif offset == 0x2000:  # ATOMIC_SET on RESET
                cur = self.peek32(RESETS_BASE + 0x00)
                cur |= value
                self.poke32(RESETS_BASE + 0x00, cur)
                self.poke32(RESETS_BASE + 0x08, ~cur & 0xFFFFFFFF)
            elif offset == 0x1000:  # XOR
                cur = self.peek32(RESETS_BASE + 0x00)
                cur ^= value
                self.poke32(RESETS_BASE + 0x00, cur)
                self.poke32(RESETS_BASE + 0x08, ~cur & 0xFFFFFFFF)
            elif offset == 0x00:  # plain write
                self.poke32(RESETS_BASE + 0x08, ~value & 0xFFFFFFFF)

        self.on_write(RESETS_BASE, 0x4000, cb)

    def mock_xosc_stable(self) -> None:
        """Auto-assert XOSC_STATUS.STABLE after the first write to XOSC_CTRL.

        Mirrors silicon: once the firmware enables XOSC, the crystal needs a
        startup window to ring up.  We model "ringup is instantaneous" by
        flipping STABLE the moment CTRL is written; the spin loop in
        xosc_init then exits on the very next read.
        """
        XOSC_BASE = 0x40048000
        XOSC_CTRL = 0x00
        XOSC_STATUS = 0x04
        XOSC_STABLE = 1 << 31

        # Pre-state: not stable.
        self.poke32(XOSC_BASE + XOSC_STATUS, 0)

        def cb(addr: int, value: int, size: int) -> None:
            offset = (addr - XOSC_BASE) & 0xFFF
            if offset == XOSC_CTRL:
                self.poke32(XOSC_BASE + XOSC_STATUS, XOSC_STABLE)

        self.on_write(XOSC_BASE, 0x4000, cb)

    def mock_pll_locked(self, base: int) -> None:
        """Auto-assert CS.LOCK after the first write to PLL_PWR.

        On real silicon LOCK takes a few hundred us to settle.  We model an
        instantaneous lock so the spin loop exits.  Pass either PLL_SYS_BASE
        (0x40050000) or PLL_USB_BASE (0x40058000).
        """
        PLL_CS = 0x00
        PLL_PWR = 0x04
        PLL_LOCK = 1 << 31

        # Default CS = 0 (REFDIV=0, no LOCK)
        self.poke32(base + PLL_CS, 0)

        # CS read returns the stored REFDIV plus LOCK once we have armed it.
        # We track armed[0] so the test can also verify it spins forever
        # without the mock.
        armed = [False]

        def write_cb(addr: int, value: int, size: int) -> None:
            offset = (addr - base) & 0xFFF
            base_off = offset & 0x0FF
            alias = offset & 0x3000
            # PWR write at any alias arms the lock.
            if base_off == PLL_PWR:
                armed[0] = True
            # If firmware writes CS (REFDIV), preserve our LOCK shadow on top.
            if base_off == PLL_CS and alias == 0:
                cur = value & 0x3F
                if armed[0]:
                    cur |= PLL_LOCK
                self.poke32(base + PLL_CS, cur)

        def read_cb(addr: int, size: int):
            offset = (addr - base) & 0xFFF
            if offset == PLL_CS:
                cur = self.peek32(base + PLL_CS)
                if armed[0]:
                    cur |= PLL_LOCK
                return cur
            return None

        self.on_write(base, 0x4000, write_cb)
        self.on_read(base, 0x4000, read_cb)

    def mock_clk_selected(self) -> None:
        """Auto-assert CLOCKS.<clk>_SELECTED to mirror the requested SRC.

        The clk_init code spins on the SELECTED bit becoming the one-hot of
        the SRC field it just wrote.  In silicon the glitchless mux takes a
        few clk_ref cycles to settle; in the harness we settle in zero time.
        """
        CLOCKS_BASE = 0x40010000
        # (offset_of_CTRL, offset_of_SELECTED, src_lsb, src_width)
        # CTRL at +0, SELECTED at +8 within each per-clock block.
        CLK_BLOCKS = {
            0x30: (0, 2),   # CLK_REF: SRC[1:0]
            0x3C: (0, 1),   # CLK_SYS: SRC[0:0]
        }

        def cb(addr: int, value: int, size: int) -> None:
            offset = (addr - CLOCKS_BASE) & 0xFFF
            for blk_off, (src_lsb, src_width) in CLK_BLOCKS.items():
                if offset == blk_off:  # CTRL plain write
                    src = (value >> src_lsb) & ((1 << src_width) - 1)
                    selected = 1 << src
                    self.poke32(CLOCKS_BASE + blk_off + 8, selected)

        self.on_write(CLOCKS_BASE, 0x1000, cb)

    def mock_resets_done_for(self, *bits: int) -> None:
        """Variant of mock_resets_done that pre-clears the named reset bits.

        Used by tests that don't want the startup-time RESETS_RESET CLR to
        affect their RESET_DONE accounting (e.g. PLL bring-up, which needs
        bits 14/15 cleared on demand).  Just a convenience over
        mock_resets_done().
        """
        self.mock_resets_done()
        # Pre-clear the bits the test expects to be available immediately.
        RESETS_BASE = 0x40020000
        cur = self.peek32(RESETS_BASE)
        for b in bits:
            cur &= ~(1 << b)
        self.poke32(RESETS_BASE, cur)
        self.poke32(RESETS_BASE + 0x08, ~cur & 0xFFFFFFFF)

    def mock_uart0_tx(self) -> List[int]:
        """Capture every byte written to UART0 DR.  Returns the list it
        appends to so a test can read transmitted bytes incrementally."""
        UART0_BASE = 0x40070000
        UART_DR = 0x00
        UART_FR = 0x18
        out: List[int] = []

        # Always report TX FIFO not full / not busy
        def fr_read(addr: int, size: int) -> int:
            return 0

        self.on_read(UART0_BASE + UART_FR, 4, fr_read)

        def dr_write(addr: int, value: int, size: int) -> None:
            offset = addr & 0xFFF
            if offset == UART_DR:
                out.append(value & 0xFF)

        # Cover plain + atomic aliases
        self.on_write(UART0_BASE, 0x4000, dr_write)
        return out

    # --------------------------------------------------------------- execution

    def run_until_pc(self, addr: int, max_steps: int = 1_000_000) -> None:
        """Run instructions until PC == addr.  Raises if max_steps hit."""
        self._stop_at_pc = addr & ~1
        self._stop_after_steps = max_steps
        self._stopped_reason = None
        start = self.uc.reg_read(UC_ARM_REG_PC) | 1  # restore Thumb bit
        # `count=0, until=0` would let it run forever.  We use a generous
        # max-instructions safety net via UC_HOOK_CODE -> emu_stop().
        self.uc.emu_start(start, until=0, count=0)
        if self._stopped_reason == "step_cap":
            raise TimeoutError(
                f"run_until_pc({addr:#x}) hit max_steps={max_steps}; "
                f"last PC={self.uc.reg_read(UC_ARM_REG_PC):#x}")

    def run_steps(self, n: int) -> None:
        """Execute exactly n instructions then stop."""
        self._stop_at_pc = None
        self._stop_after_steps = n
        self._stopped_reason = None
        start = self.uc.reg_read(UC_ARM_REG_PC) | 1
        self.uc.emu_start(start, until=0, count=n)

    def run_until_write(self, addr: int, size: int = 4,
                        max_steps: int = 1_000_000) -> MmioEvent:
        """Run until a write to `addr` is observed, return the event."""
        target = (addr, size)
        before = len(self.writes)

        # Install a one-shot hook that stops emulation once we see the write
        sentinel: List[bool] = []

        def hook(a: int, v: int, s: int) -> None:
            if a == addr:
                sentinel.append(True)
                self.uc.emu_stop()
                self._stopped_reason = "write_match"

        self.on_write(addr, size, hook)
        self._stop_after_steps = max_steps
        self._stop_at_pc = None
        self._stopped_reason = None
        start = self.uc.reg_read(UC_ARM_REG_PC) | 1
        self.uc.emu_start(start, until=0, count=0)
        # Strip the one-shot
        self._write_hooks = [h for h in self._write_hooks if h[2] is not hook]
        if not sentinel:
            raise TimeoutError(f"no write to {addr:#x} within {max_steps} steps")
        return self.writes[-1]

    def expect_writes(self, expected: List[Tuple[int, int]]) -> None:
        """Assert that the FIRST len(expected) writes match `[(addr, value), ...]`.

        Helpful as a "trace prefix" matcher so tests don't have to know the
        exact total number of writes the firmware will issue."""
        actual = [(w.addr, w.value) for w in self.writes[: len(expected)]]
        if actual != expected:
            raise AssertionError(
                "write trace mismatch:\n"
                f"  expected: {[(hex(a), hex(v)) for a, v in expected]}\n"
                f"  got:      {[(hex(a), hex(v)) for a, v in actual]}\n"
                f"  full:     {self.writes}")

    # ------------------------------------------------------------- introspect

    def symbol(self, name: str) -> int:
        if name not in self.symbols:
            raise KeyError(f"symbol {name!r} not in ELF (loaded {list(self.symbols)[:5]}...)")
        return self.symbols[name]

    def writes_to(self, base: int, size: int) -> List[MmioEvent]:
        """Subset of `writes` falling inside [base, base+size)."""
        return [w for w in self.writes if base <= w.addr < base + size]

    # ----------------------------------------------------------- internal cb

    def _on_write(self, uc: Uc, access: int, addr: int, size: int,
                  value: int, user_data) -> None:
        pc = uc.reg_read(UC_ARM_REG_PC)
        self.writes.append(MmioEvent(pc, addr, size, value & 0xFFFFFFFF, True))
        for base, region_size, fn in self._write_hooks:
            if base <= addr < base + region_size:
                fn(addr, value & 0xFFFFFFFF, size)

    def _on_read(self, uc: Uc, access: int, addr: int, size: int,
                 value: int, user_data) -> None:
        # Run user read hooks first; they may patch the underlying memory.
        for base, region_size, fn in self._read_hooks:
            if base <= addr < base + region_size:
                v = fn(addr, size)
                if v is not None:
                    if size == 4:
                        uc.mem_write(addr, struct.pack("<I", v & 0xFFFFFFFF))
                    elif size == 2:
                        uc.mem_write(addr, struct.pack("<H", v & 0xFFFF))
                    elif size == 1:
                        uc.mem_write(addr, struct.pack("<B", v & 0xFF))
        actual = struct.unpack("<I", uc.mem_read(addr, 4))[0] if size == 4 else 0
        pc = uc.reg_read(UC_ARM_REG_PC)
        self.reads.append(MmioEvent(pc, addr, size, actual, False))

    def _on_code(self, uc: Uc, addr: int, size: int, user_data) -> None:
        self._executed += 1
        if self._stop_at_pc is not None and addr == self._stop_at_pc:
            self._stopped_reason = "pc_match"
            uc.emu_stop()
            return
        cb = self._pc_hooks.get(addr)
        if cb is not None:
            cb(self)
        if (self._stop_after_steps is not None and
                self._executed >= self._stop_after_steps):
            self._stopped_reason = "step_cap"
            uc.emu_stop()


# ----------------------------------------------------------------- assembler


def assemble(src_path: str, out_dir: str, base: int = SRAM_BASE,
             include_dir: Optional[str] = None) -> str:
    """Assemble + link an .S to a flat binary at `base`.  Returns bin path."""
    import subprocess

    os.makedirs(out_dir, exist_ok=True)
    name = os.path.splitext(os.path.basename(src_path))[0]
    obj = os.path.join(out_dir, name + ".o")
    elf = os.path.join(out_dir, name + ".elf")
    bin_ = os.path.join(out_dir, name + ".bin")
    ld_script = os.path.join(out_dir, name + ".ld")

    with open(ld_script, "w") as f:
        f.write(f"""ENTRY(_start)
MEMORY {{ SRAM(rwx) : ORIGIN = {hex(base)}, LENGTH = 64K }}
SECTIONS {{
  .text {hex(base)} : {{ *(.vectors) *(.text*) *(.rodata*) }} > SRAM
}}
""")

    asflags = ["-mcpu=cortex-m33", "-mthumb", "-mimplicit-it=always"]
    if include_dir:
        asflags += ["-I", include_dir]
    subprocess.check_call(["arm-none-eabi-as", *asflags, "-o", obj, src_path])
    subprocess.check_call(["arm-none-eabi-ld", "-T", ld_script, "-nostdlib",
                           "-o", elf, obj])
    subprocess.check_call(["arm-none-eabi-objcopy", "-O", "binary", elf, bin_])
    return bin_
