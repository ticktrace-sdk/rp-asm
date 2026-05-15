"""T1: UART driver trace assertions for src/uart.S (M4-E).

Tests:
  - v0.1 regression: uart0_init produces the same writes as v0.1 (delegated
    via the existing test_v01_blinky.py; we re-verify the prefix here too
    using a UART-only fixture so a failure isolates the cause).
  - uart_init(1, 115200, 150_000_000) writes IBRD=81/FBRD=24 to UART1_BASE
    and clears the right RESETS bit.
  - uart_set_format / uart_set_hw_flow / uart_set_dma_enabled bit math.
  - uart_set_irqs_enabled / uart_acknowledge_irq target IMSC / ICR.
  - All three example UF2s build and produce expected register prefixes.

Convention mirrors tests/unicorn/test_pwm.py: build a fixture ELF that pulls
in src/uart.S + src/nvic.S, then PC-inject calls.
"""

import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim, SRAM_BASE  # noqa: E402
from mocks_uart import (  # noqa: E402
    UART0_BASE, UART1_BASE,
    UART_DR, UART_FR, UART_IBRD, UART_FBRD, UART_LCR_H, UART_CR,
    UART_IMSC, UART_ICR, UART_DMACR,
    UART_LCR_H_FEN, UART_LCR_H_PEN, UART_LCR_H_EPS, UART_LCR_H_STP2,
    UART_LCR_H_WLEN_LSB,
    UART_CR_UARTEN, UART_CR_TXE, UART_CR_RXE, UART_CR_RTSEN, UART_CR_CTSEN,
    UART_INT_RXIM, UART_INT_TXIM, UART_INT_RTIM,
    UART_DMACR_TXDMAE, UART_DMACR_RXDMAE,
    RESETS_uart0, RESETS_uart1,
    ATOMIC_CLR, ATOMIC_SET,
    uart_base, uart_writes_to,
    mock_uart_tx_capture, mock_uart_rx_data,
)
from unicorn.arm_const import (  # noqa: E402
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
    UC_ARM_REG_LR, UC_ARM_REG_PC,
)


RESETS_BASE = 0x40020000
RESETS_RESET_CLR = RESETS_BASE + ATOMIC_CLR


# ----------------------------------------------------------------- fixtures


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    """Build tests/unicorn/fixtures/uart_api.S into an ELF."""
    out = tmp_path_factory.mktemp("uart_fixture")
    src = os.path.join(HERE, "fixtures", "uart_api.S")
    obj = os.path.join(out, "uart_api.o")
    elf = os.path.join(out, "uart_api.elf")
    ld = os.path.join(out, "uart_api.ld")
    with open(ld, "w") as f:
        f.write(f"""ENTRY(_start)
MEMORY {{ SRAM(rwx) : ORIGIN = {hex(SRAM_BASE)}, LENGTH = 64K }}
SECTIONS {{
  .text {hex(SRAM_BASE)} : {{
    KEEP(*(.vectors))
    *(.text._start)
    *(.text*)
    *(.rodata*)
  }} > SRAM
  _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;
}}
""")
    asflags = ["-mcpu=cortex-m33", "-mthumb", "-mimplicit-it=always",
               "-I", os.path.join(REPO, "include")]
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", obj, src], cwd=REPO)
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld, "-nostdlib", "-o", elf, obj])
    return elf


def _load_fixture(elf):
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    return sim


def _call(sim, func_name, *args, max_steps=200_000):
    """Set r0..r{N-1} = args, point PC at func, LR at park sentinel."""
    park = sim.symbol("_park")
    func = sim.symbol(func_name)
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
    for i, v in enumerate(args):
        sim.uc.reg_write(regs[i], v & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=max_steps)


# -----------------------------------------------------------------------------
# uart_init / uart_resets_deassert
# -----------------------------------------------------------------------------


def test_uart0_init_v01_trace_prefix(fixture_elf):
    """uart0_init must produce the v0.1 byte-identical MMIO trace.

    Specifically:
      PADS_BANK0[0] CLR  = 0x180
      PADS_BANK0[1] CLR  = 0x180
      IO_BANK0[0] CTRL   = 2
      IO_BANK0[1] CTRL   = 2
      UART0 IBRD         = 6
      UART0 FBRD         = 33
      UART0 LCR_H        = 0x70
      UART0 CR           = 0x301
    """
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart0_init")

    PADS = 0x40038000
    IO = 0x40028000
    expected = [
        # uart0_init now releases UART0 from reset itself - startup.S _reset
        # only deals with io_bank0/pads_bank0 (uart0's RESET_DONE won't
        # assert there because clk_peri isn't running yet).
        (RESETS_RESET_CLR, 1 << 26),
        (PADS + ATOMIC_CLR + 4 + 0 * 4, 0x180),
        (PADS + ATOMIC_CLR + 4 + 1 * 4, 0x180),
        (IO + 4 + 0 * 8, 2),
        (IO + 4 + 1 * 8, 2),
        (UART0_BASE + UART_IBRD, 6),
        (UART0_BASE + UART_FBRD, 33),
        (UART0_BASE + UART_LCR_H, 0x70),
        (UART0_BASE + UART_CR, 0x301),
    ]
    actual = [(w.addr, w.value) for w in sim.writes]
    assert actual == expected, (
        "uart0_init trace diverges from v0.1 contract:\n"
        f"expected: {[(hex(a), hex(v)) for a, v in expected]}\n"
        f"got:      {[(hex(a), hex(v)) for a, v in actual]}"
    )


def test_uart_init_uart1_at_150mhz(fixture_elf):
    """uart_init(1, 115200, 150e6) writes IBRD=81/FBRD=24/LCR_H=0x70/CR=0x301
    to UART1_BASE and asserts CLR on RESETS bit 27 (uart1)."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_init", 1, 115200, 150_000_000)

    # First write should be RESETS_RESET CLR with mask = 1 << 27 (RESETS_uart1).
    # Filter writes so we ignore reads of RESETS_RESET_DONE (those are reads).
    rs = uart_writes_to(sim, RESETS_RESET_CLR)
    assert rs, f"no write to RESETS_RESET CLR, full trace: {sim.writes}"
    assert rs[0].value == (1 << RESETS_uart1), (
        f"expected RESETS clear of bit {RESETS_uart1}, got {rs[0].value:#x}")

    # IBRD / FBRD / LCR_H / CR on UART1_BASE
    ibrd = uart_writes_to(sim, UART1_BASE + UART_IBRD)
    fbrd = uart_writes_to(sim, UART1_BASE + UART_FBRD)
    lcr_h = uart_writes_to(sim, UART1_BASE + UART_LCR_H)
    cr = uart_writes_to(sim, UART1_BASE + UART_CR)
    assert ibrd and ibrd[-1].value == 81, (
        f"IBRD@UART1: {[(hex(w.addr), hex(w.value)) for w in ibrd]}")
    assert fbrd and fbrd[-1].value == 24, (
        f"FBRD@UART1: {[(hex(w.addr), hex(w.value)) for w in fbrd]}")
    assert lcr_h and lcr_h[-1].value == 0x70
    assert cr and cr[-1].value == 0x301


def test_uart_init_uart0_at_150mhz_uses_uart0_base(fixture_elf):
    """uart_init(0, ...) must target UART0_BASE not UART1_BASE."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_init", 0, 115200, 150_000_000)

    cr0 = uart_writes_to(sim, UART0_BASE + UART_CR)
    cr1 = uart_writes_to(sim, UART1_BASE + UART_CR)
    assert cr0 and cr0[-1].value == 0x301
    assert not cr1, f"uart_init(0) wrote to UART1 CR: {cr1}"


def test_resets_deassert_uart1(fixture_elf):
    """uart_resets_deassert(1) writes (1<<27) to RESETS_RESET CLR alias."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_resets_deassert", 1)
    ws = uart_writes_to(sim, RESETS_RESET_CLR)
    assert ws and ws[-1].value == (1 << RESETS_uart1)


def test_resets_deassert_uart0(fixture_elf):
    """uart_resets_deassert(0) writes (1<<26) to RESETS_RESET CLR alias."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_resets_deassert", 0)
    ws = uart_writes_to(sim, RESETS_RESET_CLR)
    assert ws and ws[-1].value == (1 << RESETS_uart0)


# -----------------------------------------------------------------------------
# uart_set_baudrate / uart_set_format / uart_set_hw_flow
# -----------------------------------------------------------------------------


def test_set_baudrate_115200_at_150mhz(fixture_elf):
    """uart_set_baudrate(0, 115200, 150e6) writes IBRD=81 / FBRD=24."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_set_baudrate", 0, 115200, 150_000_000)
    ibrd = uart_writes_to(sim, UART0_BASE + UART_IBRD)
    fbrd = uart_writes_to(sim, UART0_BASE + UART_FBRD)
    assert ibrd and ibrd[-1].value == 81
    assert fbrd and fbrd[-1].value == 24


def test_set_baudrate_921600_at_150mhz(fixture_elf):
    """uart_set_baudrate(0, 921600, 150e6) writes IBRD=10 / FBRD=11."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_set_baudrate", 0, 921600, 150_000_000)
    ibrd = uart_writes_to(sim, UART0_BASE + UART_IBRD)
    fbrd = uart_writes_to(sim, UART0_BASE + UART_FBRD)
    assert ibrd and ibrd[-1].value == 10
    assert fbrd and fbrd[-1].value == 11


def test_set_format_7e1_fen(fixture_elf):
    """uart_set_format(0, 7, 1, 1) -> WLEN=2, FEN preserved=1, PEN=1, EPS=1."""
    sim = _load_fixture(fixture_elf)
    # Pre-load LCR_H = 0x70 (8N1+FEN) so we can see FEN preservation.
    sim.poke32(UART0_BASE + UART_LCR_H, 0x70)
    _call(sim, "uart_set_format", 0, 7, 1, 1)
    ws = uart_writes_to(sim, UART0_BASE + UART_LCR_H)
    assert ws, f"no LCR_H write; trace: {sim.writes}"
    expected = (2 << UART_LCR_H_WLEN_LSB) | UART_LCR_H_FEN | UART_LCR_H_PEN | UART_LCR_H_EPS
    assert ws[-1].value == expected, (
        f"LCR_H expected {expected:#x}, got {ws[-1].value:#x}")


def test_set_format_8n1_no_fen(fixture_elf):
    """uart_set_format(0, 8, 1, 0) with FEN=0 in current LCR_H stays FEN=0."""
    sim = _load_fixture(fixture_elf)
    sim.poke32(UART0_BASE + UART_LCR_H, 0x60)  # WLEN=3, FEN=0 (yes the default has WLEN=3)
    _call(sim, "uart_set_format", 0, 8, 1, 0)
    ws = uart_writes_to(sim, UART0_BASE + UART_LCR_H)
    assert ws
    expected = (3 << UART_LCR_H_WLEN_LSB)  # WLEN=8b, no FEN, no parity
    assert ws[-1].value == expected, (
        f"LCR_H expected {expected:#x}, got {ws[-1].value:#x}")


def test_set_format_8n2(fixture_elf):
    """uart_set_format(0, 8, 2, 0) sets STP2 and WLEN=3."""
    sim = _load_fixture(fixture_elf)
    sim.poke32(UART0_BASE + UART_LCR_H, 0x70)
    _call(sim, "uart_set_format", 0, 8, 2, 0)
    ws = uart_writes_to(sim, UART0_BASE + UART_LCR_H)
    assert ws
    expected = (3 << UART_LCR_H_WLEN_LSB) | UART_LCR_H_FEN | UART_LCR_H_STP2
    assert ws[-1].value == expected


def test_set_hw_flow_both_on(fixture_elf):
    """uart_set_hw_flow(0, 1, 1) sets RTSEN | CTSEN, preserving CR.UARTEN/TXE/RXE."""
    sim = _load_fixture(fixture_elf)
    sim.poke32(UART0_BASE + UART_CR, 0x301)
    _call(sim, "uart_set_hw_flow", 0, 1, 1)
    ws = uart_writes_to(sim, UART0_BASE + UART_CR)
    assert ws
    expected = 0x301 | UART_CR_RTSEN | UART_CR_CTSEN
    assert ws[-1].value == expected, (
        f"CR expected {expected:#x}, got {ws[-1].value:#x}")


def test_set_hw_flow_off_only_clears(fixture_elf):
    """uart_set_hw_flow(0, 0, 0) clears RTSEN | CTSEN, preserves the rest."""
    sim = _load_fixture(fixture_elf)
    pre = 0x301 | UART_CR_RTSEN | UART_CR_CTSEN
    sim.poke32(UART0_BASE + UART_CR, pre)
    _call(sim, "uart_set_hw_flow", 0, 0, 0)
    ws = uart_writes_to(sim, UART0_BASE + UART_CR)
    assert ws and ws[-1].value == 0x301


# -----------------------------------------------------------------------------
# DMA / IRQ enable + ack
# -----------------------------------------------------------------------------


def test_set_dma_enabled_both(fixture_elf):
    """uart_set_dma_enabled(0, 1, 1) writes (TXDMAE|RXDMAE) to DMACR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_set_dma_enabled", 0, 1, 1)
    ws = uart_writes_to(sim, UART0_BASE + UART_DMACR)
    assert ws
    assert ws[-1].value == (UART_DMACR_TXDMAE | UART_DMACR_RXDMAE)


def test_set_dma_enabled_tx_only(fixture_elf):
    """uart_set_dma_enabled(1, 1, 0) writes TXDMAE alone to UART1_BASE+DMACR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_set_dma_enabled", 1, 1, 0)
    ws = uart_writes_to(sim, UART1_BASE + UART_DMACR)
    assert ws and ws[-1].value == UART_DMACR_TXDMAE


def test_set_irqs_enabled(fixture_elf):
    """uart_set_irqs_enabled(0, RXIM|TXIM) writes that mask to IMSC."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_set_irqs_enabled", 0, UART_INT_RXIM | UART_INT_TXIM)
    ws = uart_writes_to(sim, UART0_BASE + UART_IMSC)
    assert ws and ws[-1].value == (UART_INT_RXIM | UART_INT_TXIM)


def test_acknowledge_irq_rxim(fixture_elf):
    """uart_acknowledge_irq(0, RXIM) writes (1<<4) to ICR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_acknowledge_irq", 0, UART_INT_RXIM)
    ws = uart_writes_to(sim, UART0_BASE + UART_ICR)
    assert ws and ws[-1].value == (1 << 4)


def test_acknowledge_irq_uart1(fixture_elf):
    """uart_acknowledge_irq(1, RTIM) writes (1<<6) to UART1+ICR."""
    sim = _load_fixture(fixture_elf)
    _call(sim, "uart_acknowledge_irq", 1, UART_INT_RTIM)
    ws = uart_writes_to(sim, UART1_BASE + UART_ICR)
    assert ws and ws[-1].value == (1 << 6)


# -----------------------------------------------------------------------------
# is_writable / is_readable
# -----------------------------------------------------------------------------


def test_is_writable_returns_1_when_txff_clear(fixture_elf):
    """is_writable(0) returns 1 when FR.TXFF is clear."""
    sim = _load_fixture(fixture_elf)
    sim.poke32(UART0_BASE + UART_FR, 0)
    _call(sim, "uart_is_writable", 0)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1


def test_is_writable_returns_0_when_txff_set(fixture_elf):
    """is_writable(0) returns 0 when FR.TXFF is set."""
    sim = _load_fixture(fixture_elf)
    sim.poke32(UART0_BASE + UART_FR, 1 << 5)
    _call(sim, "uart_is_writable", 0)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0


def test_is_readable_returns_1_when_rxfe_clear(fixture_elf):
    """is_readable(0) returns 1 when FR.RXFE is clear."""
    sim = _load_fixture(fixture_elf)
    sim.poke32(UART0_BASE + UART_FR, 0)
    _call(sim, "uart_is_readable", 0)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 1


# -----------------------------------------------------------------------------
# putc/puts/getc with mocks
# -----------------------------------------------------------------------------


def test_uart0_puts_streams_via_compat_shim(fixture_elf):
    """uart0_puts must route into uart_puts_blocking(0, ptr) and emit the bytes."""
    sim = _load_fixture(fixture_elf)
    tx = mock_uart_tx_capture(sim, 0)

    # Stash the string in SRAM at a known address (above the fixture code).
    msg = b"hello\0"
    addr = SRAM_BASE + 0xF000
    sim.uc.mem_write(addr, msg)

    park = sim.symbol("_park")
    sim.uc.reg_write(UC_ARM_REG_R0, addr)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, sim.symbol("uart0_puts"))
    sim.run_until_pc(park, max_steps=100_000)
    assert bytes(tx) == b"hello"


def test_uart_putc_blocking_uart1(fixture_elf):
    """uart_putc_blocking(1, 0x55) lands at UART1_BASE+DR."""
    sim = _load_fixture(fixture_elf)
    tx = mock_uart_tx_capture(sim, 1)
    _call(sim, "uart_putc_blocking", 1, 0x55)
    assert tx == [0x55]


def test_uart_getc_blocking_uart0(fixture_elf):
    """uart_getc_blocking(0) returns mocked DR data, low 8 bits only."""
    sim = _load_fixture(fixture_elf)
    mock_uart_rx_data(sim, 0, [0x42])
    _call(sim, "uart_getc_blocking", 0)
    assert sim.uc.reg_read(UC_ARM_REG_R0) == 0x42


# -----------------------------------------------------------------------------
# Example UF2 build verification
# -----------------------------------------------------------------------------


def _build_example(name):
    uf2 = os.path.join(REPO, "build", f"{name}.uf2")
    elf = os.path.join(REPO, "build", f"{name}.elf")
    bin_ = os.path.join(REPO, "build", f"{name}.bin")
    if not os.path.exists(elf):
        subprocess.check_call(["make", "-C", REPO, f"build/{name}.uf2"],
                              stdout=subprocess.DEVNULL)
    assert os.path.exists(uf2), f"{uf2} not built"
    assert os.path.exists(elf), f"{elf} not built"
    return elf, bin_


def test_uart_irq_demo_builds():
    """uart_irq_demo flat binary stays under the 3 KB budget."""
    _elf, bin_ = _build_example("uart_irq_demo")
    sz = os.path.getsize(bin_)
    assert sz < 3 * 1024, f".bin size {sz} > 3 KB"


def test_uart_dma_demo_builds():
    _elf, bin_ = _build_example("uart_dma_demo")
    sz = os.path.getsize(bin_)
    assert sz < 3 * 1024, f".bin size {sz} > 3 KB"


def test_uart_loopback_demo_builds():
    _elf, bin_ = _build_example("uart_loopback_demo")
    sz = os.path.getsize(bin_)
    assert sz < 3 * 1024, f".bin size {sz} > 3 KB"


def test_uart_irq_demo_writes_imsc_with_rx_bits():
    """uart_irq_demo's main path enables RXIM|RTIM in UART0 IMSC."""
    elf, _ = _build_example("uart_irq_demo")
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()
    mock_uart_tx_capture(sim, 0)
    mock_uart_tx_capture(sim, 1)
    # Run until the firmware reaches the wfi loop label.  We can't easily
    # name-resolve a Local label so just run to the end of main with a step
    # cap that's enough for clocks bring-up + uart_init * 2 + IMSC write.
    try:
        sim.run_steps(50_000)
    except Exception:
        pass
    # Look for the IMSC write
    ws = uart_writes_to(sim, UART0_BASE + UART_IMSC)
    assert ws, f"no UART0 IMSC write in trace ({len(sim.writes)} writes)"
    assert ws[-1].value == (UART_INT_RXIM | UART_INT_RTIM)


def test_uart_dma_demo_writes_dmacr_txdmae():
    """uart_dma_demo enables TXDMAE on UART0."""
    elf, _ = _build_example("uart_dma_demo")
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()
    mock_uart_tx_capture(sim, 0)
    try:
        sim.run_steps(50_000)
    except Exception:
        pass
    ws = uart_writes_to(sim, UART0_BASE + UART_DMACR)
    assert ws, f"no UART0 DMACR write in trace ({len(sim.writes)} writes)"
    assert ws[-1].value == UART_DMACR_TXDMAE


def test_uart_loopback_demo_inits_both_uarts():
    """uart_loopback_demo writes IBRD to both UART0 and UART1."""
    elf, _ = _build_example("uart_loopback_demo")
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()
    mock_uart_tx_capture(sim, 0)
    mock_uart_tx_capture(sim, 1)
    try:
        sim.run_steps(80_000)
    except Exception:
        pass
    # Both IBRD addresses should have been written.
    w0 = uart_writes_to(sim, UART0_BASE + UART_IBRD)
    w1 = uart_writes_to(sim, UART1_BASE + UART_IBRD)
    assert w0, "UART0 IBRD never written"
    assert w1, "UART1 IBRD never written"
    # 150e6 / 16 / 921600 = 10.172 -> IBRD=10
    assert w0[-1].value == 10, f"UART0 IBRD = {w0[-1].value}"
    assert w1[-1].value == 10, f"UART1 IBRD = {w1[-1].value}"
