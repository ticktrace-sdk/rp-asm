"""T1: clock-tree bring-up trace assertions for examples/clocks_demo.S.

The clocks_demo example exercises the M2 path:

    xosc_init
        XOSC_STARTUP=47, XOSC_CTRL=ENABLE|FREQ_RANGE, spin on STABLE
    pll_sys_150_mhz  ->  pll_init(PLL_SYS_BASE, ...)
        RESETS CLR pll_sys, FBDIV=125, REFDIV=1, PWR CLR PD|VCOPD,
        spin on LOCK, PRIM=POSTDIV1<<16|POSTDIV2<<12, PWR CLR POSTDIVPD
    pll_usb_48_mhz   ->  pll_init(PLL_USB_BASE, ...)
        same shape, FBDIV=100, POSTDIV1=5, POSTDIV2=5
    clocks_init
        clk_sys.SRC=REF, clk_ref.SRC=XOSC, clk_sys.AUXSRC=PLL_SYS,
        clk_sys.SRC=AUX, clk_peri/usb/adc enables...
    tick_init
    watchdog_disable
    gpio_led_init / uart0_init / clocks_post_pll_uart_baud_fixup
    uart0_puts(banner)
    blink loop

We assert on the *order* and *values* of the key MMIO writes - not every
single write, since the firmware also touches RESETS, IO_BANK0, PADS, etc.
that we already cover in test_v01_blinky.py.
"""

import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim  # noqa: E402

CLOCKS_DEMO_ELF = os.path.join(REPO, "build", "clocks_demo.elf")

# ----- Constants (mirror include/clocks.inc) ---------------------------------
RESETS_BASE = 0x40020000
RESETS_RESET_CLR = RESETS_BASE + 0x3000
RESETS_pll_sys = 1 << 14
RESETS_pll_usb = 1 << 15

XOSC_BASE = 0x40048000
XOSC_CTRL = XOSC_BASE + 0x00
XOSC_STARTUP = XOSC_BASE + 0x0C
XOSC_CTRL_VAL = 0xAA0 | (0xFAB << 12)   # FREQ_1_15MHZ | ENABLE

PLL_SYS_BASE = 0x40050000
PLL_USB_BASE = 0x40058000
PLL_CS = 0x00
PLL_PWR = 0x04
PLL_FBDIV_INT = 0x08
PLL_PRIM = 0x0C
PLL_PWR_CLR_VCO = 0x3000 + PLL_PWR     # ATOMIC_CLR alias
PLL_PWR_CLR_PDPD = 0x3000 + PLL_PWR

CLOCKS_BASE = 0x40010000
CLOCKS_CLK_REF = CLOCKS_BASE + 0x30
CLOCKS_CLK_SYS = CLOCKS_BASE + 0x3C
CLOCKS_CLK_PERI = CLOCKS_BASE + 0x48
CLOCKS_CLK_USB = CLOCKS_BASE + 0x60
CLOCKS_CLK_ADC = CLOCKS_BASE + 0x6C

UART0_BASE = 0x40070000
UART_IBRD = 0x24
UART_FBRD = 0x28
UART_LCR_H = 0x2C

WATCHDOG_BASE = 0x400D8000

TICKS_BASE = 0x40108000

SCB_VTOR = 0xE000ED08
SIO_GPIO_OUT_XOR = 0xD0000028


def _need_elf():
    if not os.path.exists(CLOCKS_DEMO_ELF):
        subprocess.check_call(
            ["make", "-C", REPO, "build/clocks_demo.uf2"],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(CLOCKS_DEMO_ELF):
        pytest.skip(f"{CLOCKS_DEMO_ELF} missing and `make` did not produce it")


def _full_mocks(sim):
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(PLL_SYS_BASE)
    sim.mock_pll_locked(PLL_USB_BASE)
    sim.mock_clk_selected()
    sim.mock_uart0_tx()


@pytest.fixture
def sim():
    _need_elf()
    s = RP2350Sim()
    s.load_elf(CLOCKS_DEMO_ELF)
    _full_mocks(s)
    return s


def _writes_to(sim, addr):
    return [w for w in sim.writes if w.addr == addr]


# -----------------------------------------------------------------------------
# Bring-up sequence
# -----------------------------------------------------------------------------


def test_xosc_enabled_before_any_pll_writes(sim):
    """XOSC must be brought up before either PLL is touched."""
    sim.run_until_write(SIO_GPIO_OUT_XOR)

    xosc_idx = next(i for i, w in enumerate(sim.writes) if w.addr == XOSC_CTRL)
    pll_writes = [
        i for i, w in enumerate(sim.writes)
        if PLL_SYS_BASE <= w.addr < PLL_SYS_BASE + 0x4000
        or PLL_USB_BASE <= w.addr < PLL_USB_BASE + 0x4000
    ]
    assert pll_writes, "no PLL writes observed"
    assert xosc_idx < pll_writes[0], (
        f"XOSC_CTRL written at index {xosc_idx} but first PLL write is at "
        f"index {pll_writes[0]}")

    # Check the actual XOSC programming
    ctrl_writes = _writes_to(sim, XOSC_CTRL)
    assert ctrl_writes, "no XOSC_CTRL write"
    assert ctrl_writes[0].value == XOSC_CTRL_VAL, (
        f"XOSC_CTRL = {ctrl_writes[0].value:#x}, want {XOSC_CTRL_VAL:#x}")

    startup_writes = _writes_to(sim, XOSC_STARTUP)
    assert startup_writes and startup_writes[0].value == 47


def test_pll_sys_programmed_for_150_mhz(sim):
    """pll_sys: FBDIV=125, REFDIV=1, POSTDIV1=5, POSTDIV2=2."""
    sim.run_until_write(SIO_GPIO_OUT_XOR)

    fbdiv = _writes_to(sim, PLL_SYS_BASE + PLL_FBDIV_INT)
    refdiv = [w for w in _writes_to(sim, PLL_SYS_BASE + PLL_CS) if w.value & 0x3F]
    prim = _writes_to(sim, PLL_SYS_BASE + PLL_PRIM)

    assert fbdiv and fbdiv[0].value == 125, f"FBDIV={fbdiv}"
    assert refdiv and (refdiv[0].value & 0x3F) == 1, f"REFDIV CS={refdiv}"
    assert prim, "no PLL_PRIM write"
    postdiv1 = (prim[0].value >> 16) & 0x7
    postdiv2 = (prim[0].value >> 12) & 0x7
    assert postdiv1 == 5, f"POSTDIV1={postdiv1}"
    assert postdiv2 == 2, f"POSTDIV2={postdiv2}"


def test_pll_usb_programmed_for_48_mhz(sim):
    """pll_usb: FBDIV=100, REFDIV=1, POSTDIV1=5, POSTDIV2=5."""
    sim.run_until_write(SIO_GPIO_OUT_XOR)

    fbdiv = _writes_to(sim, PLL_USB_BASE + PLL_FBDIV_INT)
    prim = _writes_to(sim, PLL_USB_BASE + PLL_PRIM)
    assert fbdiv and fbdiv[0].value == 100
    assert prim
    postdiv1 = (prim[0].value >> 16) & 0x7
    postdiv2 = (prim[0].value >> 12) & 0x7
    assert postdiv1 == 5 and postdiv2 == 5, (
        f"USB POSTDIV1={postdiv1} POSTDIV2={postdiv2}")


def test_pll_taken_out_of_reset(sim):
    """RESETS CLR for pll_sys (bit 14) and pll_usb (bit 15) must fire."""
    sim.run_until_write(SIO_GPIO_OUT_XOR)
    reset_clrs = _writes_to(sim, RESETS_RESET_CLR)
    seen_pll_sys = any(w.value & RESETS_pll_sys for w in reset_clrs)
    seen_pll_usb = any(w.value & RESETS_pll_usb for w in reset_clrs)
    assert seen_pll_sys, f"pll_sys never released; reset clears: {reset_clrs}"
    assert seen_pll_usb, f"pll_usb never released; reset clears: {reset_clrs}"


def test_clk_sys_aux_set_before_src_switched(sim):
    """clk_sys AUXSRC must be set BEFORE flipping SRC=AUX (datasheet 8.1.4).

    Otherwise we'd switch into a junk aux src and clk_sys would die.
    """
    sim.run_until_write(SIO_GPIO_OUT_XOR)

    sys_writes = _writes_to(sim, CLOCKS_CLK_SYS + 0x00)
    assert len(sys_writes) >= 3, (
        f"expected >=3 clk_sys ctrl writes (REF / AUX-set / SRC=AUX), "
        f"got {sys_writes}")

    # Walk the trace: find the first write with SRC=AUX, then make sure the
    # write *before it* already has the right AUXSRC.
    src_aux_idx = None
    for i, w in enumerate(sys_writes):
        if w.value & 1:
            src_aux_idx = i
            break
    assert src_aux_idx is not None, "clk_sys never switched to AUX"
    assert src_aux_idx >= 1, (
        "clk_sys SRC=AUX was the first write - AUXSRC was never primed")
    prior = sys_writes[src_aux_idx - 1]
    aux = (prior.value >> 5) & 0x7
    assert aux == 0, (
        f"clk_sys AUXSRC was {aux} (want 0=PLL_SYS) before SRC=AUX flip")


def test_uart_baud_retuned_for_150_mhz(sim):
    """clocks_post_pll_uart_baud_fixup must update IBRD/FBRD."""
    sim.run_until_write(SIO_GPIO_OUT_XOR)

    ibrd = _writes_to(sim, UART0_BASE + UART_IBRD)
    fbrd = _writes_to(sim, UART0_BASE + UART_FBRD)
    # uart0_init writes 6/33 first, then the fixup writes 81/24.
    assert len(ibrd) >= 2, f"only saw {len(ibrd)} IBRD writes"
    assert ibrd[-1].value == 81, f"final IBRD={ibrd[-1].value}, want 81"
    assert fbrd[-1].value == 24, f"final FBRD={fbrd[-1].value}, want 24"


def test_banner_printed_via_uart(sim):
    """The banner string must hit UART0 DR after the fixup."""
    tx = sim.mock_uart0_tx.__self__  # the list that mock_uart0_tx returns
    # We already installed mock_uart0_tx in the fixture but didn't keep the
    # returned list.  Easier: re-install on a fresh sim.
    s = RP2350Sim()
    s.load_elf(CLOCKS_DEMO_ELF)
    _full_mocks(s)
    txbuf = s.mock_uart0_tx()
    s.run_until_write(SIO_GPIO_OUT_XOR)
    text = bytes(txbuf).decode("ascii", errors="replace")
    assert "150 MHz" in text, f"expected '150 MHz' in UART output, got: {text!r}"
    assert text.startswith("rp-asm M2"), f"unexpected banner prefix: {text!r}"


def test_tick_generators_started(sim):
    """tick_init must enable TIMER0/TIMER1/WATCHDOG ticks at div=12."""
    sim.run_until_write(SIO_GPIO_OUT_XOR)

    # CYCLES + CTRL pairs at offsets 0x18, 0x24, 0x30
    for blk_off, label in [(0x18, "TIMER0"), (0x24, "TIMER1"), (0x30, "WATCHDOG")]:
        cycles = _writes_to(sim, TICKS_BASE + blk_off + 0x04)
        ctrl = _writes_to(sim, TICKS_BASE + blk_off + 0x00)
        assert cycles and cycles[0].value == 12, (
            f"{label} CYCLES={cycles}")
        assert ctrl and ctrl[0].value & 1, (
            f"{label} CTRL.ENABLE not set: {ctrl}")


def test_watchdog_left_disabled(sim):
    """watchdog_disable must clear ENABLE via the atomic CLR alias."""
    sim.run_until_write(SIO_GPIO_OUT_XOR)
    wdg_clr = _writes_to(sim, WATCHDOG_BASE + 0x3000 + 0x00)
    assert wdg_clr, "watchdog_disable never wrote CTRL CLR"
    assert wdg_clr[-1].value & (1 << 31), (
        f"watchdog CTRL CLR didn't include ENABLE bit: {wdg_clr}")


# -----------------------------------------------------------------------------
# Wait-for-LOCK behaviour: without the mock, we MUST spin.
# -----------------------------------------------------------------------------


def test_pll_sys_spins_without_lock_mock():
    """Verify the LOCK wait is real - without mock_pll_locked the firmware
    never makes it past pll_sys_150_mhz.

    We give it a generous step budget (10000) and check it never reaches the
    SIO_GPIO_OUT_XOR write that signals the blink loop has started.
    """
    _need_elf()
    s = RP2350Sim()
    s.load_elf(CLOCKS_DEMO_ELF)
    s.mock_resets_done()
    s.mock_xosc_stable()
    # Deliberately omit mock_pll_locked - the wait-for-LOCK loop should hang.
    s.mock_clk_selected()
    s.mock_uart0_tx()

    import pytest as _pt
    with _pt.raises(TimeoutError):
        s.run_until_write(SIO_GPIO_OUT_XOR, max_steps=10_000)
