@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ rp2040.inc - RP2040 register map (subset used by the M2 driver set)
@
@ All offsets/bit positions cross-checked against the RP2040 datasheet
@ (Raspberry Pi RP2040 datasheet, rev 1.3, Oct 2023).
@
@ Atomic register aliases (apply to most APB peripherals):
@   +0x0000  normal RW
@   +0x1000  XOR on write
@   +0x2000  bitwise SET on write
@   +0x3000  bitwise CLR on write
@ Same shape as RP2350, but with the RP2040 peripheral base addresses.
@ =============================================================================

    .equ ATOMIC_XOR,  0x1000
    .equ ATOMIC_SET,  0x2000
    .equ ATOMIC_CLR,  0x3000

@ ---- ARMv6-M System Control Block --------------------------------------------
    .equ SCB_VTOR,    0xE000ED08

@ ---- SIO (single-cycle IO, M0+ local) ----------------------------------------
@ Same base as RP2350; layout is a strict subset (no HI-band registers because
@ the RP2040 only has 30 user GPIOs).
    .equ SIO_BASE,           0xD0000000
    .equ SIO_CPUID,          0x000
    .equ SIO_GPIO_IN,        0x004
    .equ SIO_GPIO_OUT,       0x010
    .equ SIO_GPIO_OUT_SET,   0x014
    .equ SIO_GPIO_OUT_CLR,   0x018
    .equ SIO_GPIO_OUT_XOR,   0x01C
    .equ SIO_GPIO_OE,        0x020
    .equ SIO_GPIO_OE_SET,    0x024
    .equ SIO_GPIO_OE_CLR,    0x028
    .equ SIO_GPIO_OE_XOR,    0x02C

@ ---- RESETS ------------------------------------------------------------------
    .equ RESETS_BASE,        0x4000C000
    .equ RESETS_RESET,       0x00
    .equ RESETS_WDSEL,       0x04
    .equ RESETS_RESET_DONE,  0x08

    @ Bit positions in RESETS_RESET (RP2040 sec 2.14.3).  These differ from
    @ the RP2350 layout, hence the per-chip naming.
    .equ RESETS_adc,         0
    .equ RESETS_busctrl,     1
    .equ RESETS_dma,         2
    .equ RESETS_i2c0,        3
    .equ RESETS_i2c1,        4
    .equ RESETS_io_bank0,    5
    .equ RESETS_io_qspi,     6
    .equ RESETS_jtag,        7
    .equ RESETS_pads_bank0,  8
    .equ RESETS_pads_qspi,   9
    .equ RESETS_pio0,        10
    .equ RESETS_pio1,        11
    .equ RESETS_pll_sys,     12
    .equ RESETS_pll_usb,     13
    .equ RESETS_pwm,         14
    .equ RESETS_rtc,         15
    .equ RESETS_spi0,        16
    .equ RESETS_spi1,        17
    .equ RESETS_syscfg,      18
    .equ RESETS_sysinfo,     19
    .equ RESETS_tbman,       20
    .equ RESETS_timer,       21
    .equ RESETS_uart0,       22
    .equ RESETS_uart1,       23
    .equ RESETS_usbctrl,     24

@ ---- IO_BANK0 ----------------------------------------------------------------
    .equ IO_BANK0_BASE,             0x40014000
    @ Per-GPIO block is 8 bytes: { STATUS, CTRL }. CTRL = base + 4 + n*8.
    @ Same layout as RP2350; just a different base.
    .equ IO_BANK0_GPIO_CTRL_OFFS,   0x04
    .equ IO_BANK0_GPIO_CTRL_STRIDE, 8

    @ Funcsel values used by the M2 drivers.  RP2040 PROC0 GPIO function table
    @ (datasheet sec 2.19.2): F1=SPI, F2=UART, F3=I2C, F4=PWM, F5=SIO,
    @ F6=PIO0, F7=PIO1, F8=CLOCK, F9=USB.  31 = NULL (high impedance).
    .equ GPIO_FUNC_SIO,      5
    .equ GPIO_FUNC_UART,     2
    .equ GPIO_FUNC_NULL,     31

    @ Proc0 IRQ enable registers (one byte per pin, 4 pins per word).
    .equ IO_BANK0_PROC0_INTE0,  0x100
    .equ IO_BANK0_INTR0,        0x0F0

@ ---- PADS_BANK0 --------------------------------------------------------------
    .equ PADS_BANK0_BASE,        0x4001C000
    @ Per-pad register at offset 4 + n*4 (offset 0 is VOLTAGE_SELECT).
    @ Bits: SLEWFAST=0, SCHMITT=1, PDE=2, PUE=3, DRIVE[5:4], IE=6, OD=7.
    @ RP2040 has NO ISO bit (unlike RP2350 where ISO=1 at reset and has to be
    @ cleared before the pad can drive).  Pads boot in input mode with PUE=0
    @ PDE=1 SCHMITT=1 IE=1 OD=0.
    .equ PADS_BANK0_GPIO_OFFS, 0x04
    .equ PADS_BANK0_PAD_STRIDE, 4
    .equ PADS_OD,            (1 << 7)
    .equ PADS_IE,            (1 << 6)
    .equ PADS_DRIVE_LSB,     4
    .equ PADS_DRIVE_MASK,    (3 << 4)
    .equ PADS_PUE,           (1 << 3)
    .equ PADS_PDE,           (1 << 2)
    .equ PADS_SCHMITT,       (1 << 1)
    .equ PADS_SLEWFAST,      (1 << 0)

@ ---- UART0 / UART1 (PL011) ---------------------------------------------------
    .equ UART0_BASE,         0x40034000
    .equ UART1_BASE,         0x40038000
    .equ UART_DR,            0x00
    .equ UART_FR,            0x18
    .equ UART_IBRD,          0x24
    .equ UART_FBRD,          0x28
    .equ UART_LCR_H,         0x2C
    .equ UART_CR,            0x30
    .equ UART_IMSC,          0x38
    .equ UART_ICR,           0x44
    .equ UART_DMACR,         0x48

    @ UART_FR bits
    .equ UART_FR_TXFF,       (1 << 5)
    .equ UART_FR_RXFE,       (1 << 4)
    .equ UART_FR_BUSY,       (1 << 3)

    @ UART_LCR_H bits
    .equ UART_LCR_H_FEN,     (1 << 4)
    .equ UART_LCR_H_WLEN_8,  (3 << 5)

    @ UART_CR bits
    .equ UART_CR_RXE,        (1 << 9)
    .equ UART_CR_TXE,        (1 << 8)
    .equ UART_CR_UARTEN,     (1 << 0)

@ ---- XOSC --------------------------------------------------------------------
    .equ XOSC_BASE,          0x40024000
    .equ XOSC_CTRL,          0x00
    .equ XOSC_STATUS,        0x04
    .equ XOSC_DORMANT,       0x08
    .equ XOSC_STARTUP,       0x0C

    @ XOSC_CTRL values
    @ FREQ_RANGE: 0xAA0 selects 1_15MHZ (the only valid range for the bundled
    @ 12 MHz crystal on Pico boards).  ENABLE = 0xFAB enables.
    .equ XOSC_CTRL_FREQ_1_15MHZ, 0xAA0
    .equ XOSC_CTRL_ENABLE,       (0xFAB << 12)

    @ STARTUP delay: ~1 ms with the 12 MHz crystal (datasheet sec 2.16.3).
    @ delay = 47 multiplied by 256 internally; we write the small value.
    .equ XOSC_STARTUP_DELAY, 47

@ ---- PLLs --------------------------------------------------------------------
    .equ PLL_SYS_BASE,       0x40028000
    .equ PLL_USB_BASE,       0x4002C000
    .equ PLL_CS,             0x00
    .equ PLL_PWR,            0x04
    .equ PLL_FBDIV_INT,      0x08
    .equ PLL_PRIM,           0x0C

    @ PLL_CS bits
    .equ PLL_CS_LOCK,        (1 << 31)
    .equ PLL_CS_REFDIV_LSB,  0

    @ PLL_PWR bits (a 1 powers DOWN the block)
    .equ PLL_PWR_VCOPD,      (1 << 5)
    .equ PLL_PWR_POSTDIVPD,  (1 << 3)
    .equ PLL_PWR_DSMPD,      (1 << 2)
    .equ PLL_PWR_PD,         (1 << 0)

    @ PLL_PRIM bits
    .equ PLL_PRIM_POSTDIV1_LSB, 16
    .equ PLL_PRIM_POSTDIV2_LSB, 12

@ ---- CLOCKS ------------------------------------------------------------------
    .equ CLOCKS_BASE,        0x40008000

    @ Clock generator register strides: each generator has CTRL/DIV/SELECTED
    @ at base + n*0x0C (sys is the exception - DIV is 24 bits with FRAC at LSB).
    @ For the M2 set we care about: ref(0), sys(1), peri(2), usb(3), adc(4),
    @ rtc(5).  Generator offsets:
    .equ CLK_GPOUT0_CTRL,    0x00
    .equ CLK_REF_CTRL,       0x30
    .equ CLK_REF_DIV,        0x34
    .equ CLK_REF_SELECTED,   0x38
    .equ CLK_SYS_CTRL,       0x3C
    .equ CLK_SYS_DIV,        0x40
    .equ CLK_SYS_SELECTED,   0x44
    .equ CLK_PERI_CTRL,      0x48
    .equ CLK_PERI_SELECTED,  0x50
    .equ CLK_USB_CTRL,       0x54
    .equ CLK_USB_DIV,        0x58
    .equ CLK_USB_SELECTED,   0x5C
    .equ CLK_ADC_CTRL,       0x60
    .equ CLK_ADC_DIV,        0x64
    .equ CLK_ADC_SELECTED,   0x68

    @ CTRL field values
    @ AUXSRC encoding differs per generator; for the M2 set we use:
    @   clk_sys.AUXSRC = 0 (pll_sys), .SRC = 1 (auxsrc)
    @   clk_ref.SRC = 2 (xosc), no auxsrc needed
    @   clk_peri.AUXSRC = 0 (clk_sys)
    @   clk_usb.AUXSRC = 0 (pll_usb)
    @   clk_adc.AUXSRC = 0 (pll_usb)
    .equ CLK_CTRL_ENABLE,     (1 << 11)
    .equ CLK_REF_CTRL_SRC_XOSC, 2
    .equ CLK_SYS_CTRL_SRC_AUX,  1
    .equ CLK_SYS_CTRL_AUXSRC_PLL_SYS, 0
    .equ CLK_PERI_CTRL_AUXSRC_CLK_SYS, 0
    .equ CLK_USB_CTRL_AUXSRC_PLL_USB,  0
    .equ CLK_ADC_CTRL_AUXSRC_PLL_USB,  0

@ ---- WATCHDOG ----------------------------------------------------------------
    .equ WATCHDOG_BASE,      0x40058000
    .equ WATCHDOG_CTRL,      0x00
    .equ WATCHDOG_LOAD,      0x04
    .equ WATCHDOG_REASON,    0x08
    .equ WATCHDOG_SCRATCH0,  0x0C
    .equ WATCHDOG_SCRATCH1,  0x10
    .equ WATCHDOG_SCRATCH2,  0x14
    .equ WATCHDOG_SCRATCH3,  0x18
    .equ WATCHDOG_SCRATCH4,  0x1C
    .equ WATCHDOG_SCRATCH5,  0x20
    .equ WATCHDOG_SCRATCH6,  0x24
    .equ WATCHDOG_SCRATCH7,  0x28
    .equ WATCHDOG_TICK,      0x2C

    @ CTRL bits
    .equ WATCHDOG_CTRL_TRIGGER, (1 << 31)
    .equ WATCHDOG_CTRL_ENABLE,  (1 << 30)
    .equ WATCHDOG_CTRL_PAUSE_DBG1, (1 << 26)
    .equ WATCHDOG_CTRL_PAUSE_DBG0, (1 << 25)
    .equ WATCHDOG_CTRL_PAUSE_JTAG, (1 << 24)

    @ TICK bits: bit 9 = ENABLE, bits 8:0 = CYCLES
    .equ WATCHDOG_TICK_ENABLE, (1 << 9)
    @ For the default M2 boot at clk_ref=12 MHz, CYCLES=12 produces a 1 MHz
    @ tick out of WATCHDOG_TICK that feeds TIMER and the watchdog itself.
    .equ WATCHDOG_TICK_CYCLES_12, 12

@ ---- TIMER -------------------------------------------------------------------
    .equ TIMER_BASE,         0x40054000
    .equ TIMER_TIMEHW,       0x00
    .equ TIMER_TIMELW,       0x04
    .equ TIMER_TIMEHR,       0x08
    .equ TIMER_TIMELR,       0x0C
    .equ TIMER_ALARM0,       0x10
    .equ TIMER_TIMERAWH,     0x24
    .equ TIMER_TIMERAWL,     0x28
