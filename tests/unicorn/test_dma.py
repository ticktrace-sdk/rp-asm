"""T1 trace assertions for src/dma.S + the DMA examples (M3-C).

These tests focus on the *contract* between the assembly driver and the
hardware: which exact MMIO addresses and values the firmware emits, in what
order, and that the spin loops actually exit when the mocked hardware sets
the right bit.

A separate end-to-end check builds examples/dma_memcpy_demo.elf and walks
the issued register sequence to confirm the example wires the driver
correctly (rather than re-implementing it inline).
"""

import os
import struct
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim, assemble  # noqa: E402
from mocks_dma import (                   # noqa: E402
    DMA_BASE,
    DMA_CHANNEL_STRIDE,
    DMA_INTR,
    DMA_INTE0,
    DMA_INTE1,
    DMA_INTE2,
    DMA_INTE3,
    DMA_MULTI_CHAN_TRIGGER,
    DMA_SNIFF_CTRL,
    DMA_SNIFF_DATA,
    DMA_CHAN_ABORT,
    CTRL_BUSY,
    RESETS_DMA,
    channel_base,
    map_dma_region,
    mock_dma_resets_done,
    mock_dma_finishes_after,
    mock_dma_abort_completes,
    mock_dma_functional_copy,
)

ATOMIC_SET = 0x2000
ATOMIC_CLR = 0x3000

# Per-channel offsets re-imported here as locals so the test reads cleanly.
CH_READ_ADDR = 0x00
CH_WRITE_ADDR = 0x04
CH_TRANS_COUNT = 0x08
CH_CTRL_TRIG = 0x0C
CH_AL1_CTRL = 0x10


# ----------------------------------------------------------------------------
# Build a small ELF that just contains the dma.S driver + a tiny harness so
# we can call individual DMA helpers from Unicorn.  The example ELFs cover
# the full integration; this fixture covers the unit behaviour.
# ----------------------------------------------------------------------------


DRIVER_HARNESS_SRC = r"""
    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ STACK_TOP, 0x20010000

    .section .vectors, "ax"
    .word STACK_TOP
    .word _start + 1

    .section .text._start, "ax"
    .thumb_func
    .global _start
_start:
    @ Argument layout for each entry point sits in r0..r3 already; we just
    @ jump and trap on return.  The test arranges for the LR to point at
    @ trap_return so we know when the call has come back.
    bx      r12

    .thumb_func
    .global trap_return
trap_return:
    @ Sentinel STR so the test can `run_until_pc(trap_return)` or
    @ `run_until_write(0xD00000FC)` interchangeably.
    movs    r0, #0xAA
    ldr     r1, =0xD00000FC
    str     r0, [r1]
1:  b       1b
"""


@pytest.fixture(scope="module")
def driver_obj(tmp_path_factory):
    """Assemble src/dma.S + harness into one ELF; load fresh per-test sim."""
    out = tmp_path_factory.mktemp("dma_unit")
    harness_path = os.path.join(out, "harness.S")
    with open(harness_path, "w") as f:
        f.write(DRIVER_HARNESS_SRC)
    # Build dma.S separately so we can link both into one image
    dma_obj = os.path.join(out, "dma.o")
    h_obj = os.path.join(out, "harness.o")
    elf = os.path.join(out, "img.elf")
    bin_ = os.path.join(out, "img.bin")
    ld = os.path.join(out, "img.ld")
    with open(ld, "w") as f:
        f.write("""ENTRY(_start)
MEMORY { SRAM(rwx) : ORIGIN = 0x20000000, LENGTH = 64K }
SECTIONS {
  .text 0x20000000 : {
    *(.vectors)
    . = 0x40;
    *(.text._start)
    *(.text*)
    *(.rodata*)
  } > SRAM
}
""")
    incdir = os.path.join(REPO, "include")
    asflags = ["-mcpu=cortex-m33", "-mthumb", "-mimplicit-it=always",
               "-I", incdir]
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", dma_obj,
         os.path.join(REPO, "src", "dma.S")])
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", h_obj, harness_path])
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld, "-nostdlib", "-o", elf, h_obj, dma_obj])
    subprocess.check_call(
        ["arm-none-eabi-objcopy", "-O", "binary", elf, bin_])
    return elf


def _sim_with_driver(driver_obj):
    sim = RP2350Sim()
    sim.load_elf(driver_obj)
    sim.mock_resets_done()
    map_dma_region(sim)
    return sim


def _call_driver(sim, sym_name: str, args: list) -> None:
    """Set up r0..r3 from `args`, point r12 at `sym_name`, lr at trap_return,
    then run until trap_return is reached."""
    from unicorn.arm_const import (
        UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
        UC_ARM_REG_R12, UC_ARM_REG_LR,
    )
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
    for r, v in zip(regs, list(args) + [0] * (4 - len(args))):
        sim.uc.reg_write(r, v & 0xFFFFFFFF)
    target = sim.symbol(sym_name)
    # bx requires the Thumb bit in the target register
    sim.uc.reg_write(UC_ARM_REG_R12, target | 1)
    sim.uc.reg_write(UC_ARM_REG_LR, sim.symbol("trap_return") | 1)
    sim.run_until_pc(sim.symbol("trap_return"))


# ----------------------------------------------------------------------------
# dma_init
# ----------------------------------------------------------------------------


def test_dma_init_clears_reset_bit(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_init", [])

    RESETS_BASE = 0x40020000
    clr_writes = [w for w in sim.writes
                  if w.addr == RESETS_BASE + ATOMIC_CLR]
    assert clr_writes, "dma_init never CLR'd RESETS_RESET"
    assert clr_writes[0].value == RESETS_DMA, (
        f"reset clear value {clr_writes[0].value:#x}, want {RESETS_DMA:#x}")


# ----------------------------------------------------------------------------
# dma_channel_configure - non-trigger path
# ----------------------------------------------------------------------------


def test_configure_no_trigger_writes_4_stores_in_order(driver_obj):
    sim = _sim_with_driver(driver_obj)
    # Need to push count + trig onto the stack.  Reuse the standard SP
    # (top of SRAM in our linker) and pre-poke the args.
    from unicorn.arm_const import UC_ARM_REG_SP
    sp = sim.uc.reg_read(UC_ARM_REG_SP) - 8
    sim.uc.reg_write(UC_ARM_REG_SP, sp)
    sim.uc.mem_write(sp, struct.pack("<II", 0x100, 0))   # count=256, trig=0

    # ch=0, ctrl=0xCAFE0001, read=0x20004000, write=0x20005000
    _call_driver(sim, "dma_channel_configure",
                 [0, 0xCAFE0001, 0x20004000, 0x20005000])

    base = channel_base(0)
    # Filter to channel-0 writes only
    ch_writes = [w for w in sim.writes if base <= w.addr < base + 0x40]
    addrs = [w.addr - base for w in ch_writes]
    vals = [w.value for w in ch_writes]
    # Driver order: READ_ADDR, WRITE_ADDR, TRANS_COUNT, AL1_CTRL
    assert addrs == [CH_READ_ADDR, CH_WRITE_ADDR, CH_TRANS_COUNT, CH_AL1_CTRL], (
        f"unexpected ch0 write order: {[hex(a) for a in addrs]}")
    assert vals == [0x20004000, 0x20005000, 0x100, 0xCAFE0001], (
        f"unexpected ch0 write values: {[hex(v) for v in vals]}")


def test_configure_with_trigger_uses_ctrl_trig(driver_obj):
    sim = _sim_with_driver(driver_obj)
    from unicorn.arm_const import UC_ARM_REG_SP
    sp = sim.uc.reg_read(UC_ARM_REG_SP) - 8
    sim.uc.reg_write(UC_ARM_REG_SP, sp)
    sim.uc.mem_write(sp, struct.pack("<II", 0x40, 1))    # count=64, trig=1

    _call_driver(sim, "dma_channel_configure",
                 [0, 0xDEADBEEF, 0x20006000, 0x20007000])

    base = channel_base(0)
    ch_writes = [w for w in sim.writes if base <= w.addr < base + 0x40]
    addrs = [w.addr - base for w in ch_writes]
    # Last store with trigger should land on CTRL_TRIG (0x0C), not AL1_CTRL.
    assert addrs[-1] == CH_CTRL_TRIG, (
        f"trigger path last write at offset {hex(addrs[-1])}, want CTRL_TRIG")
    assert ch_writes[-1].value == 0xDEADBEEF


# ----------------------------------------------------------------------------
# dma_channel_set_* setters
# ----------------------------------------------------------------------------


def test_set_read_writes_al1_read_addr(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_set_read", [3, 0x20008000])
    base = channel_base(3)
    ws = [w for w in sim.writes if base <= w.addr < base + 0x40]
    assert len(ws) == 1
    assert ws[0].addr - base == 0x14   # AL1_READ_ADDR
    assert ws[0].value == 0x20008000


def test_set_write_writes_al1_write_addr(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_set_write", [3, 0x2000A000])
    base = channel_base(3)
    ws = [w for w in sim.writes if base <= w.addr < base + 0x40]
    assert len(ws) == 1
    assert ws[0].addr - base == 0x18   # AL1_WRITE_ADDR


def test_set_trans_count_uses_non_trig_offset(driver_obj):
    """TRANS_COUNT setter must NOT trigger the channel.

    Driver routes through the canonical TRANS_COUNT @ 0x08 (non-triggering)
    rather than the AL1 TRANS_COUNT_TRIG at 0x1C.
    """
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_set_trans_count", [5, 0x40])
    base = channel_base(5)
    ws = [w for w in sim.writes if base <= w.addr < base + 0x40]
    assert len(ws) == 1
    assert ws[0].addr - base == CH_TRANS_COUNT, (
        f"set_trans_count wrote offset {hex(ws[0].addr - base)} "
        f"(would trigger if it lands on AL1_TRANS_COUNT_TRIG @ 0x1C)")


def test_set_ctrl_uses_al1_ctrl(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_set_ctrl", [7, 0x12345678])
    base = channel_base(7)
    ws = [w for w in sim.writes if base <= w.addr < base + 0x40]
    assert len(ws) == 1
    assert ws[0].addr - base == CH_AL1_CTRL


# ----------------------------------------------------------------------------
# dma_channel_start
# ----------------------------------------------------------------------------


def test_start_writes_one_hot_to_multi_chan_trigger(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_start", [4])

    target = DMA_BASE + DMA_MULTI_CHAN_TRIGGER
    ws = [w for w in sim.writes if w.addr == target]
    assert len(ws) == 1
    assert ws[0].value == (1 << 4)


# ----------------------------------------------------------------------------
# dma_channel_wait_for_finish - polls CTRL_TRIG.BUSY
# ----------------------------------------------------------------------------


def test_wait_for_finish_polls_ctrl_busy_then_exits(driver_obj):
    sim = _sim_with_driver(driver_obj)
    state = mock_dma_finishes_after(sim, ch=0, n_polls=3)
    _call_driver(sim, "dma_channel_wait_for_finish", [0])
    # Driver must have polled CTRL_TRIG until BUSY=0 (4 reads: 3 BUSY + 1 idle)
    assert state["reads"] >= 4, (
        f"expected >= 4 polls, got {state['reads']}; "
        "driver may have skipped the busy=1 case")


def test_wait_for_finish_polls_correct_channel(driver_obj):
    sim = _sim_with_driver(driver_obj)
    state = mock_dma_finishes_after(sim, ch=2, n_polls=1)
    _call_driver(sim, "dma_channel_wait_for_finish", [2])
    assert state["reads"] >= 2


# ----------------------------------------------------------------------------
# dma_channel_abort
# ----------------------------------------------------------------------------


def test_abort_writes_one_hot_then_spins_until_clear(driver_obj):
    sim = _sim_with_driver(driver_obj)
    mock_dma_abort_completes(sim)
    _call_driver(sim, "dma_channel_abort", [9])

    target = DMA_BASE + DMA_CHAN_ABORT
    ws = [w for w in sim.writes if w.addr == target]
    assert ws, "dma_channel_abort never wrote DMA_CHAN_ABORT"
    assert ws[0].value == (1 << 9)


# ----------------------------------------------------------------------------
# dma_channel_irq_enable
# ----------------------------------------------------------------------------


def test_irq_enable_writes_atomic_set_on_inte_aggregator(driver_obj):
    """For aggregator 1, the SET alias address is DMA_BASE + ATOMIC_SET + INTE1."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_irq_enable", [3, 1])

    target = DMA_BASE + ATOMIC_SET + DMA_INTE1
    ws = [w for w in sim.writes if w.addr == target]
    assert ws, (
        f"expected SET write at {hex(target)}; got writes "
        f"{[(hex(w.addr), hex(w.value)) for w in sim.writes]}")
    assert ws[0].value == (1 << 3), (
        f"INTE1 SET value {ws[0].value:#x}, want {(1<<3):#x}")


def test_irq_enable_aggregator_0(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_irq_enable", [5, 0])
    target = DMA_BASE + ATOMIC_SET + DMA_INTE0
    ws = [w for w in sim.writes if w.addr == target]
    assert ws and ws[0].value == (1 << 5)


def test_irq_enable_aggregator_2(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_irq_enable", [7, 2])
    target = DMA_BASE + ATOMIC_SET + DMA_INTE2
    ws = [w for w in sim.writes if w.addr == target]
    assert ws and ws[0].value == (1 << 7)


# ----------------------------------------------------------------------------
# dma_channel_acknowledge_irq
# ----------------------------------------------------------------------------


def test_ack_irq_writes_one_hot_to_intr(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_channel_acknowledge_irq", [11, 0])
    target = DMA_BASE + DMA_INTR
    ws = [w for w in sim.writes if w.addr == target]
    assert ws and ws[0].value == (1 << 11)


# ----------------------------------------------------------------------------
# dma_sniff_*
# ----------------------------------------------------------------------------


def test_sniff_enable_writes_ctrl_with_correct_fields(driver_obj):
    """SNIFF_CTRL = (mode<<5) | (ch<<1) | EN."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "dma_sniff_enable", [4, 0])  # ch=4, mode=CRC32

    sniff_target = DMA_BASE + DMA_SNIFF_CTRL
    ws = [w for w in sim.writes if w.addr == sniff_target]
    assert ws, "no SNIFF_CTRL write observed"
    expected = (0 << 5) | (4 << 1) | 1
    assert ws[0].value == expected, (
        f"SNIFF_CTRL = {ws[0].value:#x}, want {expected:#x}")

    # And SNIFF_DATA should have been pre-zeroed
    data_target = DMA_BASE + DMA_SNIFF_DATA
    dws = [w for w in sim.writes if w.addr == data_target]
    assert dws and dws[0].value == 0, (
        "dma_sniff_enable should pre-zero SNIFF_DATA so the accumulator "
        "starts fresh")


def test_sniff_get_data_returns_register(driver_obj):
    sim = _sim_with_driver(driver_obj)
    sim.poke32(DMA_BASE + DMA_SNIFF_DATA, 0xCAFEBABE)
    _call_driver(sim, "dma_sniff_get_data", [])
    from unicorn.arm_const import UC_ARM_REG_R0
    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    assert r0 == 0xCAFEBABE, f"r0 = {r0:#x}, want 0xCAFEBABE"


# ----------------------------------------------------------------------------
# End-to-end check: the example wires the driver correctly.
# ----------------------------------------------------------------------------


DMA_MEMCPY_ELF = os.path.join(REPO, "build", "dma_memcpy_demo.elf")


def _need_memcpy_elf():
    if not os.path.exists(DMA_MEMCPY_ELF):
        subprocess.check_call(
            ["make", "-C", REPO, "build/dma_memcpy_demo.uf2"],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(DMA_MEMCPY_ELF):
        pytest.skip(f"{DMA_MEMCPY_ELF} missing and `make` did not produce it")


def test_memcpy_demo_issues_full_register_sequence():
    """The example must:
      1. CLR DMA reset bit
      2. Configure channel 0 with src/dst/count and trigger
      3. Spin on CTRL.BUSY
      4. Re-zero dst, then a CPU memcpy
    We assert on (1) and (2) at minimum, and that wait_for_finish actually
    polled CH0_CTRL_TRIG before continuing.
    """
    _need_memcpy_elf()
    sim = RP2350Sim()
    sim.load_elf(DMA_MEMCPY_ELF)
    sim.mock_resets_done()
    map_dma_region(sim)
    mock_dma_resets_done(sim)
    sim.mock_uart0_tx()

    state = mock_dma_functional_copy(sim)

    # Run until the first SIO_GPIO_OUT_XOR (the post-DMA blink).  That tells
    # us we got past every DMA call, the verify loop, and into the park.
    sim.run_until_write(0xD0000028, max_steps=2_000_000)

    # 1. DMA reset bit was cleared
    RESETS_BASE = 0x40020000
    clr_writes = [w for w in sim.writes
                  if w.addr == RESETS_BASE + ATOMIC_CLR]
    assert any(w.value & RESETS_DMA for w in clr_writes), (
        "DMA reset bit never cleared - dma_init may not have run")

    # 2. Channel 0 saw a configure + trigger
    base0 = channel_base(0)
    ch0_writes = [w for w in sim.writes if base0 <= w.addr < base0 + 0x40]
    addrs = [w.addr - base0 for w in ch0_writes]
    assert CH_READ_ADDR in addrs
    assert CH_WRITE_ADDR in addrs
    assert CH_TRANS_COUNT in addrs
    assert CH_CTRL_TRIG in addrs, "trigger path never landed on CTRL_TRIG"

    # 3. The functional mock confirms count=256 (1 KiB / 4) and ctrl is the
    # MEM2MEM word constant from include/dma.inc.
    assert state[0]["count"] == 256, (
        f"channel-0 TRANS_COUNT shadowed as {state[0]['count']}, want 256")

    # CTRL must have EN=1, DATA_SIZE_WORD (bits 3:2 = 2), INCR_READ + WRITE
    ctrl = state[0]["ctrl"]
    assert ctrl & 1, f"EN not set in CTRL ({ctrl:#x})"
    assert (ctrl >> 2) & 3 == 2, f"DATA_SIZE not WORD ({ctrl:#x})"
    assert (ctrl >> 4) & 1, f"INCR_READ not set ({ctrl:#x})"
    assert (ctrl >> 6) & 1, f"INCR_WRITE not set ({ctrl:#x})"


def test_memcpy_demo_uart_announces_dma_and_cpu_cycles():
    """The example prints 'DMA OK' and 'CPU' on its UART output."""
    _need_memcpy_elf()
    sim = RP2350Sim()
    sim.load_elf(DMA_MEMCPY_ELF)
    sim.mock_resets_done()
    map_dma_region(sim)
    mock_dma_resets_done(sim)
    tx = sim.mock_uart0_tx()
    mock_dma_functional_copy(sim)

    sim.run_until_write(0xD0000028, max_steps=2_000_000)

    text = bytes(tx).decode("ascii", errors="replace")
    assert "DMA OK" in text, f"expected 'DMA OK', got: {text!r}"
    assert "CPU" in text, f"expected 'CPU', got: {text!r}"
    # And no mismatch banner
    assert "MISMATCH" not in text, (
        f"DMA copy mismatched the source data: {text!r}")
