@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ clocks.inc - RP2350 clock-tree, XOSC, PLL_SYS, PLL_USB, watchdog, POWMAN,
@              TICKS register defs (M2 - clocks / reset / power).
@
@ All offsets / bitfields cross-checked against the RP2350 datasheet rev 0.3
@ (Aug 2024).  Section numbers below reference that revision.
@
@ Atomic register aliases (apply to most APB peripherals, NOT POWMAN):
@   +0x0000  RW
@   +0x1000  XOR on write
@   +0x2000  SET on write
@   +0x3000  CLR on write
@ POWMAN does NOT expose atomic aliases - every write must include the
@ 0x5afe password in the upper half (datasheet sec 6.5.2).
@ =============================================================================
@
@ This file is `.include`-d in addition to rp2350.inc; do not duplicate
@ definitions that already live there (RESETS, SCB_VTOR, ATOMIC_*, ...).
@
@ Conventions:
@   - all *_BASE constants are absolute byte addresses
@   - all *_OFFS / *_<reg> constants are byte offsets relative to *_BASE
@   - bit positions are named *_LSB; mask helpers use `(1 << *_LSB)`
@ =============================================================================

@ ----- XOSC (datasheet sec 8.2) -----------------------------------------------
@   12 MHz crystal off-chip on Pico 2; we drive it via XOSC, then route
@   it through the PLLs.
    .equ XOSC_BASE,             0x40048000
    .equ XOSC_CTRL,             0x00
    .equ XOSC_STATUS,           0x04
    .equ XOSC_DORMANT,          0x08
    .equ XOSC_STARTUP,          0x0C
    .equ XOSC_COUNT,            0x10

    @ XOSC_CTRL:
    @   [11:0]  FREQ_RANGE     (0xAA0 = 1_15MHZ, default)
    @   [23:12] ENABLE          (0xFAB = ENABLE, 0xD1E = DISABLE)
    @ Note datasheet uses magic constants for these fields.
    .equ XOSC_CTRL_FREQ_1_15MHZ, 0xAA0
    .equ XOSC_CTRL_ENABLE,       (0xFAB << 12)
    .equ XOSC_CTRL_DISABLE,      (0xD1E << 12)

    @ XOSC_STATUS:
    @   [31]    STABLE   (RO, set by HW once startup delay elapsed)
    .equ XOSC_STATUS_STABLE,    (1 << 31)

    @ XOSC_STARTUP DELAY field is [13:0]; total cycles = (DELAY * 256).
    @ Datasheet recommends ((freq_kHz * t_stable_ms) + 128) / 256.
    @ For a 12 MHz xtal with a 1 ms target startup window:
    @   ((12_000 * 1) + 128) / 256 = 47.5  -> use 48 (~1.0ms).
    @ The Pico 2 default in the bootrom uses 47, matching the SDK's
    @ PICO_XOSC_STARTUP_DELAY_MULTIPLIER=1.
    .equ XOSC_STARTUP_DELAY,    47

@ ----- ROSC (datasheet sec 8.3) -----------------------------------------------
    .equ ROSC_BASE,             0x400E8000
    .equ ROSC_CTRL,             0x00
    .equ ROSC_STATUS,           0x18

@ ----- PLL_SYS / PLL_USB (datasheet sec 8.6) ---------------------------------
@   Both PLLs use the same register map.
    .equ PLL_SYS_BASE,          0x40050000
    .equ PLL_USB_BASE,          0x40058000

    .equ PLL_CS,                0x00      @ control / status
    .equ PLL_PWR,               0x04
    .equ PLL_FBDIV_INT,         0x08
    .equ PLL_PRIM,              0x0C      @ POSTDIV1, POSTDIV2

    @ PLL_CS:
    @   [0:5]   REFDIV
    @   [8]     BYPASS
    @   [31]    LOCK     (RO)
    .equ PLL_CS_LOCK,           (1 << 31)
    .equ PLL_CS_BYPASS,         (1 << 8)
    .equ PLL_CS_REFDIV_LSB,     0

    @ PLL_PWR:
    @   [0]   PD          (main power-down)
    @   [2]   DSMPD       (delta-sigma power-down)
    @   [3]   POSTDIVPD
    @   [5]   VCOPD
    .equ PLL_PWR_PD,            (1 << 0)
    .equ PLL_PWR_DSMPD,         (1 << 2)
    .equ PLL_PWR_POSTDIVPD,     (1 << 3)
    .equ PLL_PWR_VCOPD,         (1 << 5)
    .equ PLL_PWR_ALL,           (PLL_PWR_PD | PLL_PWR_DSMPD | PLL_PWR_POSTDIVPD | PLL_PWR_VCOPD)

    @ PLL_PRIM:
    @   [12:14] POSTDIV2
    @   [16:18] POSTDIV1
    .equ PLL_PRIM_POSTDIV2_LSB, 12
    .equ PLL_PRIM_POSTDIV1_LSB, 16

    @ RESETS bit positions for the PLLs (datasheet sec 7.5).
    .equ RESETS_pll_sys,        14
    .equ RESETS_pll_usb,        15

@ ----- CLOCKS (datasheet sec 8.1) --------------------------------------------
@   Per-clock generator block layout (40 B stride):
@     +0x00 CTRL
@     +0x04 DIV
@     +0x08 SELECTED   (RO; one-hot of currently active SRC)
@   Sub-blocks (offsets from CLOCKS_BASE):
@     CLK_GPOUT0  0x00     (4 GPOUT slots)
@     CLK_GPOUT1  0x0C
@     CLK_GPOUT2  0x18
@     CLK_GPOUT3  0x24
@     CLK_REF     0x30
@     CLK_SYS     0x3C
@     CLK_PERI    0x48
@     CLK_HSTX    0x54
@     CLK_USB     0x60
@     CLK_ADC     0x6C
@   On RP2350 there is no separate CLK_RTC (RTC moved into POWMAN).
    .equ CLOCKS_BASE,           0x40010000
    .equ CLOCKS_CLK_REF,        0x30
    .equ CLOCKS_CLK_SYS,        0x3C
    .equ CLOCKS_CLK_PERI,       0x48
    .equ CLOCKS_CLK_USB,        0x60
    .equ CLOCKS_CLK_ADC,        0x6C

    @ Per-clock register offsets (relative to the per-clock base above)
    .equ CLK_CTRL,              0x00
    .equ CLK_DIV,               0x04
    .equ CLK_SELECTED,          0x08

    @ CLK_REF_CTRL:
    @   [1:0]   SRC      (0=ROSC, 1=AUX, 2=XOSC)
    @   [6:5]   AUXSRC   (0=PLL_USB, 1=GPIN0, 2=GPIN1)
    .equ CLK_REF_SRC_ROSC,      0
    .equ CLK_REF_SRC_AUX,       1
    .equ CLK_REF_SRC_XOSC,      2

    @ CLK_SYS_CTRL:
    @   [0]     SRC      (0=CLK_REF, 1=AUX)
    @   [7:5]   AUXSRC   (0=PLL_SYS, 1=PLL_USB, 2=ROSC, 3=XOSC, ...)
    .equ CLK_SYS_SRC_REF,       0
    .equ CLK_SYS_SRC_AUX,       1
    .equ CLK_SYS_AUXSRC_PLL_SYS,(0 << 5)
    .equ CLK_SYS_AUXSRC_PLL_USB,(1 << 5)

    @ CLK_PERI_CTRL:
    @   [11]    ENABLE
    @   [7:5]   AUXSRC   (0=CLK_SYS, 1=PLL_SYS, 2=PLL_USB, 3=ROSC, 4=XOSC)
    .equ CLK_PERI_ENABLE,       (1 << 11)
    .equ CLK_PERI_AUXSRC_SYS,   (0 << 5)
    .equ CLK_PERI_AUXSRC_PLL_SYS,(1 << 5)

    @ CLK_USB_CTRL / CLK_ADC_CTRL share layout:
    @   [11]    ENABLE
    @   [7:5]   AUXSRC   (0=PLL_USB, 1=PLL_SYS, ...)
    .equ CLK_USBADC_ENABLE,     (1 << 11)
    .equ CLK_USBADC_AUXSRC_PLL_USB, (0 << 5)

@ ----- WATCHDOG (datasheet sec 12.9) -----------------------------------------
    .equ WATCHDOG_BASE,         0x400D8000
    .equ WATCHDOG_CTRL,         0x00
    .equ WATCHDOG_LOAD,         0x04
    .equ WATCHDOG_REASON,       0x08
    .equ WATCHDOG_SCRATCH0,     0x0C

    @ WATCHDOG_CTRL (RP2350 datasheet sec 12.9):
    @   [23:0]  TIME         countdown in ticks of the WDG TICK (1 us, RO)
    @   [24]    PAUSE_JTAG
    @   [25]    PAUSE_DBG0
    @   [26]    PAUSE_DBG1
    @   [30]    ENABLE       when not enabled the watchdog timer is paused
    @   [31]    TRIGGER      writing 1 triggers an immediate watchdog reset
    .equ WATCHDOG_CTRL_ENABLE,  (1 << 30)
    .equ WATCHDOG_CTRL_TRIGGER, (1 << 31)
    .equ WATCHDOG_TICK_HZ,      1000000   @ tick is 1 MHz, so TIME in microseconds

@ ----- POWMAN (datasheet sec 6.5) --------------------------------------------
@   Replaces RP2040's VREG_AND_CHIP_RESET; also hosts the always-on RTC and
@   the POR/BOR knobs.  Every register write *must* include the password
@   0x5afe in the upper 16 bits, otherwise the write is silently dropped.
    .equ POWMAN_BASE,           0x40100000
    .equ POWMAN_PASSWORD,       0x5AFE0000

    .equ POWMAN_VREG,           0x04   @ AON regulator config (low half = VREG_VOLTAGE_*)
    .equ POWMAN_CHIP_RESET,     0x08

@ ----- TICKS (datasheet sec 8.5) ---------------------------------------------
@   One TICKS peripheral, six sub-tickers.  Each is 12 bytes:
@     +0  CTRL    [0]=ENABLE, [1]=RUNNING (RO)
@     +4  CYCLES  divider (clk_ref cycles per tick)
@     +8  COUNT   (RO) current cycle counter
@   The 12 MHz XOSC-derived clk_ref divided by 12 gives a 1 us tick.
    .equ TICKS_BASE,            0x40108000

    .equ TICKS_PROC0_OFFS,      0x00
    .equ TICKS_PROC1_OFFS,      0x0C
    .equ TICKS_TIMER0_OFFS,     0x18
    .equ TICKS_TIMER1_OFFS,     0x24
    .equ TICKS_WATCHDOG_OFFS,   0x30
    .equ TICKS_RISCV_OFFS,      0x3C

    .equ TICKS_CTRL,            0x00
    .equ TICKS_CYCLES,          0x04
    .equ TICKS_COUNT,           0x08

    .equ TICKS_CTRL_ENABLE,     (1 << 0)
    .equ TICKS_CYCLES_DIV_1MHZ, 12      @ 12 MHz / 12 = 1 MHz

@ ----- M2 baud divisors for UART0 @ clk_peri = 150 MHz -----------------------
@   150e6 / (16 * 115200) = 81.380...
@   IBRD = 81
@   FBRD = round(0.380 * 64) = round(24.3) = 24
@   actual = 150e6 / (16 * (81 + 24/64)) = 115211 Bd  (-0.01% error)
    .equ UART_IBRD_150MHZ,      81
    .equ UART_FBRD_150MHZ,      24
