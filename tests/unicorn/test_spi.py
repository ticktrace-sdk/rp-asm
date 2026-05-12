"""T1 trace assertions for src/spi.S + the SPI examples (M4-G).

The harness asserts on the EXACT MMIO traffic the driver emits:
addresses, values, and the order in which the firmware's PL022 register
writes appear.  A handful of end-to-end checks build the example UF2s and
verify the driver was wired in correctly (rather than re-implementing
PL022 init inline).
"""

import os
import struct
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim                                            # noqa: E402
from mocks_spi import (                                                  # noqa: E402
    SPI0_BASE, SPI1_BASE,
    SSPCR0, SSPCR1, SSPDR, SSPSR, SSPCPSR, SSPIMSC, SSPICR, SSPDMACR,
    SSPSR_TFE, SSPSR_TNF, SSPSR_RNE, SSPSR_BSY,
    SSPCR1_LBM, SSPCR1_SSE, SSPCR1_MS,
    SSPDMACR_TXDMAE, SSPDMACR_RXDMAE,
    RESETS_SPI0, RESETS_SPI1,
    spi_base,
    mock_spi_resets_done,
    mock_spi_status,
    mock_spi_loopback,
    mock_spi_cr1_readback,
)

ATOMIC_SET = 0x2000
ATOMIC_CLR = 0x3000
RESETS_BASE = 0x40020000

# Frame format encodings (already shifted into bits [5:4])
FRF_MOTOROLA = 0 << 4
FRF_TI_SSI = 1 << 4
FRF_NS_MICROWIRE = 2 << 4


# ---------------------------------------------------------------------------
# Build a tiny ELF that contains src/spi.S + a stub that lets us call the
# driver's entry points individually.  The same trick is used by the DMA
# test suite in test_dma.py; see that file for the rationale.
# ---------------------------------------------------------------------------

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
    bx      r12

    .thumb_func
    .global trap_return
trap_return:
    movs    r0, #0xAA
    ldr     r1, =0xD00000FC
    str     r0, [r1]
1:  b       1b
"""


@pytest.fixture(scope="module")
def driver_obj(tmp_path_factory):
    """Assemble src/spi.S + harness stub + GPIO driver into one ELF."""
    out = tmp_path_factory.mktemp("spi_unit")
    harness_path = os.path.join(out, "harness.S")
    with open(harness_path, "w") as f:
        f.write(DRIVER_HARNESS_SRC)
    spi_obj = os.path.join(out, "spi.o")
    gpio_obj = os.path.join(out, "gpio.o")
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
        ["arm-none-eabi-as", *asflags, "-o", spi_obj,
         os.path.join(REPO, "src", "spi.S")])
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", gpio_obj,
         os.path.join(REPO, "src", "gpio.S")])
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", h_obj, harness_path])
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld, "-nostdlib", "-o", elf,
         h_obj, spi_obj, gpio_obj])
    subprocess.check_call(
        ["arm-none-eabi-objcopy", "-O", "binary", elf, bin_])
    return elf


def _sim_with_driver(driver_obj):
    sim = RP2350Sim()
    sim.load_elf(driver_obj)
    sim.mock_resets_done()
    mock_spi_resets_done(sim)
    return sim


def _call_driver(sim, sym_name: str, args: list) -> None:
    """Set up r0..r3 from `args`, point r12 at `sym_name`, lr at trap_return,
    then run until trap_return is reached.  Resets PC to _start so the
    same sim can be reused across multiple driver calls within one test."""
    from unicorn.arm_const import (
        UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
        UC_ARM_REG_R12, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_SP,
    )
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
    for r, v in zip(regs, list(args) + [0] * (4 - len(args))):
        sim.uc.reg_write(r, v & 0xFFFFFFFF)
    target = sim.symbol(sym_name)
    sim.uc.reg_write(UC_ARM_REG_R12, target | 1)
    sim.uc.reg_write(UC_ARM_REG_LR, sim.symbol("trap_return") | 1)
    # Re-seed PC at _start (which does `bx r12`) so this routine is
    # idempotent across repeated invocations on the same sim.
    sim.uc.reg_write(UC_ARM_REG_PC, sim.symbol("_start"))
    sim.run_until_pc(sim.symbol("trap_return"))


# ============================================================================
# spi_init - register sequence
# ============================================================================


def test_spi_init_clears_reset_bit(driver_obj):
    """spi_init(0, 1MHz) should CLR bit 18 of RESETS_RESET."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])

    clr_writes = [w for w in sim.writes
                  if w.addr == RESETS_BASE + ATOMIC_CLR]
    assert clr_writes, "spi_init never CLR'd RESETS_RESET"
    assert clr_writes[0].value == RESETS_SPI0, (
        f"reset clear value {clr_writes[0].value:#x}, want {RESETS_SPI0:#x}")


def test_spi_init_idx1_clears_correct_bit(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [1, 1_000_000])
    clr_writes = [w for w in sim.writes
                  if w.addr == RESETS_BASE + ATOMIC_CLR]
    assert clr_writes and clr_writes[0].value == RESETS_SPI1


def test_spi_init_writes_default_cr0_then_cr1_then_cpsr(driver_obj):
    """Init order: CR0 (8-bit Motorola) -> CR1 (master, SSE off) -> CPSR=0,
    then spi_set_baudrate runs which re-touches CPSR + CR0, and finally CR1
    gets SSE = 1.  We assert on the prefix sequence + the final CR1 write."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])

    base = SPI0_BASE
    # Filter to SPI0 register space
    ws = [w for w in sim.writes if base <= w.addr < base + 0x40]
    addrs = [w.addr - base for w in ws]
    vals = [w.value for w in ws]

    # First three SPI writes should be CR0, CR1, CPSR (initial defaults)
    assert addrs[:3] == [SSPCR0, SSPCR1, SSPCPSR], (
        f"init prefix wrote {[hex(a) for a in addrs[:3]]}; "
        "want SSPCR0, SSPCR1, SSPCPSR")
    assert vals[0] == 0x07, (
        f"default CR0 = {vals[0]:#x}; want 0x07 (DSS=7 = 8-bit, FRF=0, "
        "CPOL=CPHA=0)")
    assert vals[1] == 0x00, (
        f"default CR1 = {vals[1]:#x}; want 0x00 (master, SSE off)")
    assert vals[2] == 0x00, f"default CPSR = {vals[2]:#x}; want 0x00"

    # Final CR1 write must set SSE=1 (bit 1 = 0x02)
    cr1_writes = [w for w in ws if (w.addr - base) == SSPCR1]
    assert cr1_writes[-1].value & SSPCR1_SSE, (
        f"final CR1 = {cr1_writes[-1].value:#x}; SSE bit not set")


def test_spi_init_baud_1mhz_at_150mhz_clk_peri(driver_obj):
    """spi_init(0, 1_000_000) with clk_peri=150 MHz -> CPSDVSR=2, SCR=74.
    Writing CPSR=2 and CR0 SCR field = 74<<8 = 0x4A00 (with low byte = 0x07).
    """
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])

    base = SPI0_BASE
    ws = [w for w in sim.writes if base <= w.addr < base + 0x40]
    cpsr_writes = [w for w in ws if (w.addr - base) == SSPCPSR]
    cr0_writes = [w for w in ws if (w.addr - base) == SSPCR0]

    # Final CPSR after baudrate programming
    assert cpsr_writes[-1].value == 2, (
        f"CPSR final = {cpsr_writes[-1].value}; want 2")
    # Final CR0 should have SCR=74 (high byte) plus DSS=7 (low byte)
    final_cr0 = cr0_writes[-1].value
    scr = (final_cr0 >> 8) & 0xFF
    dss = final_cr0 & 0xF
    assert scr == 74, f"SCR = {scr}; want 74"
    assert dss == 7, f"DSS = {dss}; want 7 (8-bit)"


# ============================================================================
# spi_set_baudrate
# ============================================================================


def test_set_baudrate_4mhz(driver_obj):
    """Run spi_init at 1 MHz first, then re-program baud to 4 MHz.
    For 4 MHz at clk_peri=150 MHz: prescale=2, postdiv=round(150/8)=19,
    SCR=18 (achieved baud = 150e6/(2*19) ~= 3.95 MHz)."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [1, 1_000_000])
    sim.writes.clear()
    sim.reads.clear()
    _call_driver(sim, "spi_set_baudrate", [1, 4_000_000])

    base = SPI1_BASE
    ws = [w for w in sim.writes if base <= w.addr < base + 0x40]
    cpsr_writes = [w for w in ws if (w.addr - base) == SSPCPSR]
    cr0_writes = [w for w in ws if (w.addr - base) == SSPCR0]
    assert cpsr_writes[-1].value == 2
    scr = (cr0_writes[-1].value >> 8) & 0xFF
    assert scr == 18, f"4 MHz: SCR = {scr}; want 18"


def test_set_baudrate_returns_achieved(driver_obj):
    """spi_set_baudrate returns achieved baud in r0."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    sim.writes.clear()
    _call_driver(sim, "spi_set_baudrate", [0, 1_000_000])
    from unicorn.arm_const import UC_ARM_REG_R0
    achieved = sim.uc.reg_read(UC_ARM_REG_R0)
    assert achieved == 1_000_000, (
        f"achieved baud {achieved}; want exactly 1_000_000 "
        "(150e6 / (2*75))")


# ============================================================================
# spi_set_format
# ============================================================================


def test_set_format_16bit_cpol_cpha(driver_obj):
    """spi_set_format(0, 16, 1, 1, FRF_MOTOROLA) -> DSS=15, SPO=1, SPH=1."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    sim.writes.clear()
    # Pass frame_format on the stack ([sp,#0])
    from unicorn.arm_const import UC_ARM_REG_SP
    sp = sim.uc.reg_read(UC_ARM_REG_SP) - 8
    sim.uc.reg_write(UC_ARM_REG_SP, sp)
    sim.uc.mem_write(sp, struct.pack("<I", FRF_MOTOROLA))
    _call_driver(sim, "spi_set_format", [0, 16, 1, 1])

    base = SPI0_BASE
    cr0_writes = [w for w in sim.writes
                  if base <= w.addr < base + 0x40 and (w.addr - base) == SSPCR0]
    assert cr0_writes, "spi_set_format never wrote CR0"
    last = cr0_writes[-1].value
    dss = last & 0xF
    spo = (last >> 6) & 1
    sph = (last >> 7) & 1
    frf = (last >> 4) & 0x3
    assert dss == 15, f"DSS = {dss}; want 15 (16-bit)"
    assert spo == 1, "SPO bit not set"
    assert sph == 1, "SPH bit not set"
    assert frf == 0, "FRF should be Motorola (0)"


def test_set_format_8bit_ti(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    sim.writes.clear()
    from unicorn.arm_const import UC_ARM_REG_SP
    sp = sim.uc.reg_read(UC_ARM_REG_SP) - 8
    sim.uc.reg_write(UC_ARM_REG_SP, sp)
    sim.uc.mem_write(sp, struct.pack("<I", FRF_TI_SSI))
    _call_driver(sim, "spi_set_format", [0, 8, 0, 0])
    base = SPI0_BASE
    cr0_writes = [w for w in sim.writes
                  if base <= w.addr < base + 0x40 and (w.addr - base) == SSPCR0]
    last = cr0_writes[-1].value
    assert (last & 0xF) == 7, "DSS != 7 for 8-bit"
    assert ((last >> 4) & 0x3) == 1, "FRF not TI"


# ============================================================================
# spi_set_loopback / spi_set_slave
# ============================================================================


def test_set_loopback_toggles_lbm_with_sse_dance(driver_obj):
    """Setting loopback should clear SSE first, set LBM, then write new CR1."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    sim.writes.clear()
    _call_driver(sim, "spi_set_loopback", [0, 1])

    base = SPI0_BASE
    cr1_writes = [w for w in sim.writes
                  if base <= w.addr < base + 0x40 and (w.addr - base) == SSPCR1]
    assert len(cr1_writes) >= 2, (
        f"set_loopback wrote CR1 {len(cr1_writes)}x; want >= 2 (SSE off, "
        "then LBM with SSE restored)")
    # First write: SSE clear (bit 1 = 0)
    assert (cr1_writes[0].value & SSPCR1_SSE) == 0, (
        f"first CR1 = {cr1_writes[0].value:#x}; SSE not cleared")
    # Final write: LBM set
    assert (cr1_writes[-1].value & SSPCR1_LBM), (
        f"final CR1 = {cr1_writes[-1].value:#x}; LBM not set")


def test_set_loopback_off_clears_lbm(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    _call_driver(sim, "spi_set_loopback", [0, 1])
    sim.writes.clear()
    _call_driver(sim, "spi_set_loopback", [0, 0])

    base = SPI0_BASE
    cr1_writes = [w for w in sim.writes
                  if base <= w.addr < base + 0x40 and (w.addr - base) == SSPCR1]
    assert (cr1_writes[-1].value & SSPCR1_LBM) == 0, (
        f"final CR1 = {cr1_writes[-1].value:#x}; LBM still set")


def test_set_slave_ms_bit(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [1, 1_000_000])
    sim.writes.clear()
    _call_driver(sim, "spi_set_slave", [1, 1])
    base = SPI1_BASE
    cr1_writes = [w for w in sim.writes
                  if base <= w.addr < base + 0x40 and (w.addr - base) == SSPCR1]
    assert cr1_writes[-1].value & SSPCR1_MS, (
        f"final CR1 = {cr1_writes[-1].value:#x}; MS bit not set")


# ============================================================================
# spi_write_blocking - polls TNF, stores to SSPDR, drains RX
# ============================================================================


def test_write_blocking_stores_n_bytes_to_sspdr(driver_obj):
    """Push 4 bytes through spi_write_blocking; mock_spi_loopback captures
    them and reports them back via tx[]."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    state = mock_spi_loopback(sim, 0)
    sim.writes.clear()

    # Place a 4-byte source in SRAM
    src = 0x20002000
    payload = b"\xDE\xAD\xBE\xEF"
    sim.uc.mem_write(src, payload)
    _call_driver(sim, "spi_write_blocking", [0, src, len(payload)])

    base = SPI0_BASE
    dr_writes = [w for w in sim.writes
                 if base <= w.addr < base + 0x40 and (w.addr - base) == SSPDR]
    assert len(dr_writes) == 4, f"expected 4 DR writes, got {len(dr_writes)}"
    assert [w.value & 0xFF for w in dr_writes] == list(payload), (
        f"DR write values {[hex(w.value) for w in dr_writes]} != payload "
        f"{list(payload)}")


def test_write_blocking_returns_len(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    mock_spi_loopback(sim, 0)
    src = 0x20002000
    sim.uc.mem_write(src, b"\x01\x02\x03")
    _call_driver(sim, "spi_write_blocking", [0, src, 3])
    from unicorn.arm_const import UC_ARM_REG_R0
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 3


# ============================================================================
# spi_write_read_blocking - full duplex via the loopback model
# ============================================================================


def test_write_read_blocking_full_duplex(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    mock_spi_loopback(sim, 0)

    src = 0x20002000
    dst = 0x20003000
    payload = bytes(range(16))
    sim.uc.mem_write(src, payload)
    _call_driver(sim, "spi_write_read_blocking", [0, src, dst, len(payload)])

    rx = bytes(sim.uc.mem_read(dst, len(payload)))
    assert rx == payload, (
        f"full-duplex returned {rx!r}; want {payload!r} (loopback should "
        "echo every TX byte back)")


# ============================================================================
# spi_set_dma_enabled
# ============================================================================


def test_set_dma_enabled_both_writes_combined_mask(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    sim.writes.clear()
    _call_driver(sim, "spi_set_dma_enabled", [0, 1, 1])

    base = SPI0_BASE
    dmacr_writes = [w for w in sim.writes
                    if base <= w.addr < base + 0x40
                    and (w.addr - base) == SSPDMACR]
    assert dmacr_writes, "no SSPDMACR write"
    expected = SSPDMACR_TXDMAE | SSPDMACR_RXDMAE
    assert dmacr_writes[-1].value == expected, (
        f"DMACR = {dmacr_writes[-1].value:#x}; want {expected:#x}")


def test_set_dma_enabled_tx_only(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    sim.writes.clear()
    _call_driver(sim, "spi_set_dma_enabled", [0, 1, 0])
    base = SPI0_BASE
    dmacr_writes = [w for w in sim.writes
                    if base <= w.addr < base + 0x40
                    and (w.addr - base) == SSPDMACR]
    assert dmacr_writes[-1].value == SSPDMACR_TXDMAE


def test_set_dma_enabled_neither(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_init", [0, 1_000_000])
    sim.writes.clear()
    _call_driver(sim, "spi_set_dma_enabled", [0, 0, 0])
    base = SPI0_BASE
    dmacr_writes = [w for w in sim.writes
                    if base <= w.addr < base + 0x40
                    and (w.addr - base) == SSPDMACR]
    assert dmacr_writes[-1].value == 0


# ============================================================================
# spi_set_irqs_enabled / spi_clear_irq
# ============================================================================


def test_set_irqs_enabled_writes_imsc(driver_obj):
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_set_irqs_enabled", [0, 0xF])
    base = SPI0_BASE
    imsc_writes = [w for w in sim.writes
                   if base <= w.addr < base + 0x40
                   and (w.addr - base) == SSPIMSC]
    assert imsc_writes and imsc_writes[-1].value == 0xF


def test_clear_irq_only_w1c_bits(driver_obj):
    """SSPICR W1C only honours RORIC|RTIC = 0x3."""
    sim = _sim_with_driver(driver_obj)
    _call_driver(sim, "spi_clear_irq", [1, 0xF])
    base = SPI1_BASE
    icr_writes = [w for w in sim.writes
                  if base <= w.addr < base + 0x40
                  and (w.addr - base) == SSPICR]
    assert icr_writes and icr_writes[-1].value == 0x3


# ============================================================================
# spi_is_writable / spi_is_readable / spi_is_busy - probe SSPSR
# ============================================================================


def test_is_writable_reads_tnf_bit(driver_obj):
    sim = _sim_with_driver(driver_obj)
    mock_spi_status(sim, 0, SSPSR_TNF | SSPSR_TFE)
    _call_driver(sim, "spi_is_writable", [0])
    from unicorn.arm_const import UC_ARM_REG_R0
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1


def test_is_writable_returns_zero_when_full(driver_obj):
    sim = _sim_with_driver(driver_obj)
    mock_spi_status(sim, 0, 0)        # TNF clear -> FIFO full
    _call_driver(sim, "spi_is_writable", [0])
    from unicorn.arm_const import UC_ARM_REG_R0
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0


def test_is_readable_reads_rne_bit(driver_obj):
    sim = _sim_with_driver(driver_obj)
    mock_spi_status(sim, 1, SSPSR_RNE)
    _call_driver(sim, "spi_is_readable", [1])
    from unicorn.arm_const import UC_ARM_REG_R0
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1


def test_is_busy_reads_bsy_bit(driver_obj):
    sim = _sim_with_driver(driver_obj)
    mock_spi_status(sim, 0, SSPSR_BSY)
    _call_driver(sim, "spi_is_busy", [0])
    from unicorn.arm_const import UC_ARM_REG_R0
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1


# ============================================================================
# End-to-end: build the example UF2s and verify they wire the driver in
# ============================================================================


SPI_LOOPBACK_ELF = os.path.join(REPO, "build", "spi_loopback_demo.elf")
SPI_DMA_ELF      = os.path.join(REPO, "build", "spi_dma_demo.elf")
SPI_MS_ELF       = os.path.join(REPO, "build", "spi_master_slave_loopback_demo.elf")


def _need_elf(path: str, target: str) -> None:
    if not os.path.exists(path):
        subprocess.check_call(["make", "-C", REPO, target],
                              stdout=subprocess.DEVNULL)
    if not os.path.exists(path):
        pytest.skip(f"{path} missing and make did not produce it")


def test_loopback_demo_builds_and_runs():
    _need_elf(SPI_LOOPBACK_ELF, "build/spi_loopback_demo.uf2")
    sim = RP2350Sim()
    sim.load_elf(SPI_LOOPBACK_ELF)
    sim.mock_resets_done()
    mock_spi_resets_done(sim)
    tx_bytes = sim.mock_uart0_tx()
    mock_spi_loopback(sim, 0)

    # Run until the LED toggle (post-result park).
    sim.run_until_write(0xD0000028, max_steps=5_000_000)
    text = bytes(tx_bytes).decode("ascii", errors="replace")
    assert "PASS" in text, f"expected PASS, got: {text!r}"
    assert "FAIL" not in text


def test_dma_demo_builds():
    """Just verify the example assembles + the SPI DMA enable register
    actually got set to (TXDMAE|RXDMAE).  The full DMA pipeline isn't run
    here (mock_dma_functional_copy + mock_spi_loopback don't compose
    cleanly without an SPI<->DMA bridge), but the static register sequence
    is the load-bearing contract for T1."""
    _need_elf(SPI_DMA_ELF, "build/spi_dma_demo.uf2")
    sim = RP2350Sim()
    sim.load_elf(SPI_DMA_ELF)
    sim.mock_resets_done()
    mock_spi_resets_done(sim)
    sim.mock_uart0_tx()
    # We can't easily run to completion without modelling the DMA<->SPI
    # data path; instead, run for a bounded number of steps and check the
    # SPI DMA enable + the DMA channel CTRL writes.
    try:
        sim.run_steps(200_000)
    except Exception:
        # may bail at an unmapped DMA region access; that's fine - the
        # writes we care about happen well before that.
        pass

    base = SPI0_BASE
    dmacr = [w for w in sim.writes
             if base <= w.addr < base + 0x40
             and (w.addr - base) == SSPDMACR]
    assert dmacr, "spi_dma_demo never wrote SSPDMACR"
    assert dmacr[-1].value == (SSPDMACR_TXDMAE | SSPDMACR_RXDMAE), (
        f"DMACR final = {dmacr[-1].value:#x}; want both DMA enables")


def test_master_slave_demo_builds():
    """Verify both SPI instances are initialised and SPI1 is configured as
    slave (CR1.MS = 1)."""
    _need_elf(SPI_MS_ELF, "build/spi_master_slave_loopback_demo.uf2")
    sim = RP2350Sim()
    sim.load_elf(SPI_MS_ELF)
    sim.mock_resets_done()
    mock_spi_resets_done(sim)
    sim.mock_uart0_tx()
    # Pre-load both loopback fakes so the master-side spi_write_blocking
    # exits.  Slave-side SPI1 also needs status synthesis.
    mock_spi_loopback(sim, 0)
    mock_spi_loopback(sim, 1)

    try:
        sim.run_until_write(0xD0000028, max_steps=10_000_000)
    except Exception:
        pass

    # SPI1 slave bit should have been set somewhere in the trace
    cr1_writes = [w for w in sim.writes
                  if SPI1_BASE <= w.addr < SPI1_BASE + 0x40
                  and (w.addr - SPI1_BASE) == SSPCR1]
    assert any(w.value & SSPCR1_MS for w in cr1_writes), (
        "SPI1 was never configured as slave (no CR1.MS write observed)")

    # Both instances came out of reset
    clr_writes = [w for w in sim.writes
                  if w.addr == RESETS_BASE + ATOMIC_CLR]
    cleared = 0
    for w in clr_writes:
        if w.value & RESETS_SPI0:
            cleared |= 1
        if w.value & RESETS_SPI1:
            cleared |= 2
    assert cleared == 3, f"only some SPI reset bits were cleared (mask {cleared:#b})"
