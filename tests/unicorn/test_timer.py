"""T1: TIMER0 / TIMER1 + NVIC trace assertions for M3-B.

The drivers under test (src/timer.S, src/nvic.S, src/systick.S) are
.include'd into the example ELFs and the test fixture
(`fixtures/timer_api.S`) so we don't have to extend the Makefile DRIVER_SRC
list.

We test:
  1. `time_us_32` reads TIMER0_BASE + 0x28 (TIMERAWL).
  2. `delay_us(N)` spins until TIMERAWL crosses start+N.
  3. `alarm_set(0, 1, 0x1234, 0)` writes 0x1234 to TIMER0_BASE + 0x14 and
     clears the corresponding INTR bit.
  4. `nvic_enable_irq(0)` writes (1<<0) to NVIC ISER[0] = 0xE000E100.
  5. `nvic_install_handler(0, addr)` patches the in-RAM vector at
     _vectors + 16*4 + 0*4.
  6. `timer_delay_demo.elf` produces at least 5 LED toggles when run with
     a fast-running mock timer.
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim, SRAM_BASE                # noqa: E402
from mocks_timer import (                                # noqa: E402
    TIMER0_BASE, TIMER1_BASE,
    TIMER_TIMERAWL, TIMER_ALARM0, TIMER_INTR,
    mock_timer_running, fast_forward,
)


TIMER_DELAY_ELF = os.path.join(REPO, "build", "timer_delay_demo.elf")
TIMER_ALARM_ELF = os.path.join(REPO, "build", "timer_alarm_demo.elf")
SYSTICK_ELF     = os.path.join(REPO, "build", "systick_demo.elf")
FIXTURE_SRC     = os.path.join(HERE, "fixtures", "timer_api.S")
FIXTURE_OUT_DIR = os.path.join(REPO, "build", "_t1_fixtures")
FIXTURE_ELF     = os.path.join(FIXTURE_OUT_DIR, "timer_api.elf")

NVIC_ISER0      = 0xE000E100
NVIC_IPR_BASE   = 0xE000E400
SCB_VTOR        = 0xE000ED08

PLL_SYS_BASE    = 0x40050000
PLL_USB_BASE    = 0x40058000

SIO_GPIO_OUT_XOR = 0xD0000028
LED_BIT          = 1 << 25


def _need_elf(path: str, target: str):
    if not os.path.exists(path):
        subprocess.check_call(
            ["make", "-C", REPO, target],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(path):
        pytest.skip(f"{path} missing and `make` did not produce it")


def _build_fixture():
    """Assemble + link tests/unicorn/fixtures/timer_api.S into an ELF that
    keeps every public M3-B symbol (no --gc-sections in the local script).

    We invoke the toolchain from REPO so `.include "src/timer.S"` resolves.
    """
    os.makedirs(FIXTURE_OUT_DIR, exist_ok=True)
    obj = os.path.join(FIXTURE_OUT_DIR, "timer_api.o")
    elf = FIXTURE_ELF
    ld_script = os.path.join(FIXTURE_OUT_DIR, "timer_api.ld")
    with open(ld_script, "w") as f:
        f.write(
            "ENTRY(_start)\n"
            "MEMORY { SRAM(rwx) : ORIGIN = 0x20000000, LENGTH = 512K }\n"
            "SECTIONS {\n"
            "  .text 0x20000000 : {\n"
            "    KEEP(*(.vectors))\n"
            "    *(.text*)\n"
            "    *(.rodata*)\n"
            "  } > SRAM\n"
            "}\n"
        )
    subprocess.check_call(
        ["arm-none-eabi-as",
         "-mcpu=cortex-m33", "-mthumb", "-mimplicit-it=always",
         "-I", os.path.join(REPO, "include"),
         "-o", obj, FIXTURE_SRC],
        cwd=REPO,
    )
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld_script, "-nostdlib", "-o", elf, obj],
        cwd=REPO,
    )
    return elf


def _full_clock_mocks(sim):
    """The same mock set test_clocks uses, so the M2 boot path completes."""
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(PLL_SYS_BASE)
    sim.mock_pll_locked(PLL_USB_BASE)
    sim.mock_clk_selected()
    sim.mock_uart0_tx()


@pytest.fixture(scope="module")
def fixture_elf():
    return _build_fixture()


def _fresh_sim_fixture(fixture_elf):
    sim = RP2350Sim()
    sim.load_elf(fixture_elf)
    return sim


def _call(sim, sym: str, *args):
    """Set up a mini calling convention: r0..r3 = args, LR = sentinel,
    PC = sym.  Run until LR.  Returns r0 at the end."""
    from unicorn.arm_const import (
        UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
        UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_SP,
    )
    sentinel = 0x20070000        # well above any real .text in our ELF
    # Make sure SP is reset for each call so push/pop balance is independent.
    sim.uc.reg_write(UC_ARM_REG_SP, 0x20080000)
    for reg, val in zip((UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3), args):
        sim.uc.reg_write(reg, val & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, sentinel | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, sim.symbol(sym))
    sim.run_until_pc(sentinel, max_steps=2_000_000)
    return sim.uc.reg_read(UC_ARM_REG_R0)


# -----------------------------------------------------------------------------
# Pure-API tests against the timer_api fixture (every public symbol kept).
# -----------------------------------------------------------------------------


# ---- time_us_32 -------------------------------------------------------------


def test_time_us_32_reads_timer0_timerawl(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    state = mock_timer_running(sim, ticks_per_call=1)

    r0 = _call(sim, "time_us_32")

    rawl_reads = [r for r in sim.reads if r.addr == TIMER0_BASE + TIMER_TIMERAWL]
    assert rawl_reads, "time_us_32 didn't touch TIMER0 TIMERAWL"
    assert r0 == 1, f"time_us_32 returned {r0}, expected 1"


def test_time_us_64_uses_latch_protocol(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    mock_timer_running(sim, ticks_per_call=1)

    _call(sim, "time_us_64")

    # Must read TIMELR before TIMEHR.
    timer_reads = [r for r in sim.reads
                   if TIMER0_BASE <= r.addr < TIMER0_BASE + 0x40]
    addrs = [r.addr for r in timer_reads]
    assert TIMER0_BASE + 0x0c in addrs, "time_us_64 didn't read TIMELR"
    assert TIMER0_BASE + 0x08 in addrs, "time_us_64 didn't read TIMEHR"
    lr_idx = addrs.index(TIMER0_BASE + 0x0c)
    hr_idx = addrs.index(TIMER0_BASE + 0x08)
    assert lr_idx < hr_idx, "time_us_64 must read TIMELR before TIMEHR"


# ---- delay_us ---------------------------------------------------------------


def test_delay_us_spins_until_timerawl_advances(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    mock_timer_running(sim, ticks_per_call=1)

    _call(sim, "delay_us", 100)

    rawl_reads = [r for r in sim.reads if r.addr == TIMER0_BASE + TIMER_TIMERAWL]
    # Need start + at least 100 polls.
    assert len(rawl_reads) >= 101, (
        f"delay_us(100) only polled TIMERAWL {len(rawl_reads)} times")


def test_delay_us_terminates_with_fast_tick_rate(fixture_elf):
    """Sanity: with ticks_per_call >= us, the loop must terminate quickly."""
    sim = _fresh_sim_fixture(fixture_elf)
    mock_timer_running(sim, ticks_per_call=200)
    _call(sim, "delay_us", 100)
    # If we got here without TimeoutError, the loop exited.


# ---- alarm_set --------------------------------------------------------------


def test_alarm_set_writes_alarm_register_and_clears_intr(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    mock_timer_running(sim, ticks_per_call=1)

    # alarm_set(timer_idx=0, alarm_idx=1, target_lo=0x1234, target_hi=0)
    _call(sim, "alarm_set", 0, 1, 0x1234, 0)

    intr_writes = [w for w in sim.writes if w.addr == TIMER0_BASE + TIMER_INTR]
    assert intr_writes, "alarm_set didn't W1C INTR"
    assert intr_writes[0].value == (1 << 1), (
        f"alarm_set cleared INTR with value {intr_writes[0].value:#x}; "
        f"expected (1<<1)")

    alarm_writes = [w for w in sim.writes if w.addr == TIMER0_BASE + TIMER_ALARM0 + 4]
    assert alarm_writes, "alarm_set didn't write ALARM1"
    assert alarm_writes[-1].value == 0x1234, (
        f"ALARM1 = {alarm_writes[-1].value:#x}, want 0x1234")


def test_alarm_set_targets_timer1_when_idx_is_one(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    mock_timer_running(sim, ticks_per_call=1, base=TIMER1_BASE)

    _call(sim, "alarm_set", 1, 0, 0xCAFE, 0)

    alarm_writes = [w for w in sim.writes if w.addr == TIMER1_BASE + TIMER_ALARM0]
    assert alarm_writes and alarm_writes[-1].value == 0xCAFE, (
        f"TIMER1 ALARM0 not set as expected: {alarm_writes}")


# ---- alarm_cancel -----------------------------------------------------------


def test_alarm_cancel_writes_armed_w1c(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    mock_timer_running(sim, ticks_per_call=1)

    _call(sim, "alarm_cancel", 0, 2)

    armed_writes = [w for w in sim.writes if w.addr == TIMER0_BASE + 0x20]
    assert armed_writes and armed_writes[-1].value == (1 << 2), (
        f"alarm_cancel didn't W1C ARMED bit 2: {armed_writes}")


# ---- alarm_clear_irq --------------------------------------------------------


def test_alarm_clear_irq_writes_intr_w1c(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    mock_timer_running(sim, ticks_per_call=1)
    _call(sim, "alarm_clear_irq", 0, 3)
    intr_writes = [w for w in sim.writes if w.addr == TIMER0_BASE + TIMER_INTR]
    assert intr_writes and intr_writes[-1].value == (1 << 3)


# ---- NVIC -------------------------------------------------------------------


def test_nvic_enable_irq_sets_iser0_bit(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    _call(sim, "nvic_enable_irq", 0)

    iser_writes = [w for w in sim.writes if w.addr == NVIC_ISER0]
    assert iser_writes and iser_writes[-1].value == (1 << 0), (
        f"nvic_enable_irq(0) -> ISER[0]={iser_writes[-1].value:#x}, want 0x1")


def test_nvic_enable_irq_handles_high_irq_number(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    _call(sim, "nvic_enable_irq", 33)
    iser1_writes = [w for w in sim.writes if w.addr == NVIC_ISER0 + 4]
    assert iser1_writes and iser1_writes[-1].value == (1 << 1), (
        f"nvic_enable_irq(33) -> ISER[1]={iser1_writes[-1].value:#x}, want 0x2")


def test_nvic_set_priority_writes_iprn_byte(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    _call(sim, "nvic_set_priority", 2, 3)
    ipr_writes = [w for w in sim.writes
                  if NVIC_IPR_BASE <= w.addr < NVIC_IPR_BASE + 0x100
                  and w.size == 1]
    assert ipr_writes, f"set_priority: no byte writes to IPR"
    last = ipr_writes[-1]
    assert last.addr == NVIC_IPR_BASE + 2, (
        f"set_priority wrote IPR @ {last.addr:#x}, expected {NVIC_IPR_BASE+2:#x}")
    assert last.value == (3 << 4), (
        f"IPR[2] = {last.value:#x}, want {3<<4:#x}")


def test_nvic_install_handler_patches_in_ram_vector_table(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    sim.poke32(SCB_VTOR, 0x20000000)

    handler = 0x20001234
    _call(sim, "nvic_install_handler", 0, handler)

    vec_word = sim.peek32(0x20000000 + 16 * 4 + 0 * 4)
    assert vec_word == (handler | 1), (
        f"vec[16] = {vec_word:#x}, want {(handler|1):#x}")


def test_nvic_install_handler_for_high_irq(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    sim.poke32(SCB_VTOR, 0x20000000)

    handler = 0x20009998     # even -> Thumb bit will be OR'd
    _call(sim, "nvic_install_handler", 7, handler)

    vec_word = sim.peek32(0x20000000 + (16 + 7) * 4)
    assert vec_word == (handler | 1)


# ---- SysTick / RESETS -------------------------------------------------------


def test_systick_start_periodic_writes_csr_rvr_cvr(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    _call(sim, "systick_start_periodic", 149_999)
    SYST_CSR = 0xE000E010
    SYST_RVR = 0xE000E014
    SYST_CVR = 0xE000E018
    csr_writes = [w for w in sim.writes if w.addr == SYST_CSR]
    rvr_writes = [w for w in sim.writes if w.addr == SYST_RVR]
    cvr_writes = [w for w in sim.writes if w.addr == SYST_CVR]
    assert csr_writes and rvr_writes and cvr_writes
    # Final CSR write enables ENABLE|TICKINT|CLKSOURCE = 0b111 = 7
    assert csr_writes[-1].value == 0x7, f"final CSR={csr_writes[-1].value:#x}"
    assert rvr_writes[-1].value == 149_999
    assert cvr_writes[-1].value == 0


def test_timer_init_releases_timer_resets(fixture_elf):
    sim = _fresh_sim_fixture(fixture_elf)
    sim.mock_resets_done()
    mock_timer_running(sim)
    _call(sim, "timer_init")

    RESETS_RESET_CLR = 0x40020000 + 0x3000
    clr_writes = [w for w in sim.writes if w.addr == RESETS_RESET_CLR]
    assert clr_writes, "timer_init didn't issue a RESETS CLR"
    mask = clr_writes[-1].value
    assert mask & (1 << 23), f"timer0 bit (23) not cleared; mask={mask:#x}"
    assert mask & (1 << 24), f"timer1 bit (24) not cleared; mask={mask:#x}"


# -----------------------------------------------------------------------------
# Integration: build/timer_delay_demo.elf must hit at least 5 LED toggles
# when run with a fast-running mock timer.
# -----------------------------------------------------------------------------


def test_timer_delay_demo_blinks_at_least_5_times():
    _need_elf(TIMER_DELAY_ELF, "build/timer_delay_demo.uf2")
    sim = RP2350Sim()
    sim.load_elf(TIMER_DELAY_ELF)
    _full_clock_mocks(sim)
    # Crank ticks_per_call so delay_ms(250) returns in a handful of polls
    # instead of 250 000.  Without this the test takes minutes.
    mock_timer_running(sim, ticks_per_call=10_000_000)

    toggles = []

    def on_toggle(addr, value, size):
        toggles.append(value)

    sim.on_write(SIO_GPIO_OUT_XOR, 4, on_toggle)
    sim.run_steps(2_000_000)

    led_toggles = [t for t in toggles if t == LED_BIT]
    assert len(led_toggles) >= 5, (
        f"only {len(led_toggles)} LED toggle(s) observed; need >= 5")
