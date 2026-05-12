@ =============================================================================
@ pads.inc - PADS_BANK0 + PADS_QSPI register map and bit definitions.
@
@ Cross-checked against RP2350 datasheet rev 0.3 (Aug 2024) sec 9.3 (PADS).
@
@ Atomic register aliases (+0x1000 XOR / +0x2000 SET / +0x3000 CLR) apply.
@
@ This file is `.include`-d alongside rp2350.inc and intentionally does NOT
@ redefine PADS_BANK0_BASE, PADS_BANK0_PAD_STRIDE, PADS_ISO, PADS_OD, PADS_IE
@ which already live there.
@ =============================================================================

@ ---- Per-pad register layout (datasheet sec 9.3.1) -------------------------
@   PADS_BANK0:
@     +0x00  VOLTAGE_SELECT     (bank-wide, 1=1.8V, 0=3.3V)
@     +0x04  GPIO[0]
@     +0x08  GPIO[1]
@      ...
@     +0x04 + n*4   GPIO[n]
@     +0xC4  SWCLK
@     +0xC8  SWD
@   Per-pad register fields (lowest-bit-first):
@     [0]  SLEWFAST
@     [1]  SCHMITT     (default 1)
@     [2]  PDE         (pull-down enable)
@     [3]  PUE         (pull-up enable)
@     [5:4] DRIVE       (0=2mA, 1=4mA, 2=8mA, 3=12mA; reset 1=4mA)
@     [6]  IE          (input enable; reset 0 - pads start input-disabled)
@     [7]  OD          (output disable; reset 1 - pads start output-disabled)
@     [8]  ISO         (isolation; reset 1 - pads start isolated)
    .equ PADS_BANK0_VOLTAGE_SELECT,   0x00
    .equ PADS_BANK0_GPIO_OFFS,        4
    .equ PADS_BANK0_NUM_PADS,         48

@ Bit positions (some already in rp2350.inc; redefine guarded).
    .equ PADS_SLEWFAST_LSB,           0
    .equ PADS_SCHMITT_LSB,            1
    .equ PADS_PDE_LSB,                2
    .equ PADS_PUE_LSB,                3
    .equ PADS_DRIVE_LSB,              4
    .equ PADS_DRIVE_MASK,             (3 << 4)
    .equ PADS_IE_LSB,                 6
    .equ PADS_OD_LSB,                 7
    .equ PADS_ISO_LSB,                8

    .equ PADS_SLEWFAST,               (1 << 0)
    .equ PADS_SCHMITT,                (1 << 1)
    .equ PADS_PDE,                    (1 << 2)
    .equ PADS_PUE,                    (1 << 3)
    .ifndef PADS_IE
        .equ PADS_IE,                 (1 << 6)
    .endif
    .ifndef PADS_OD
        .equ PADS_OD,                 (1 << 7)
    .endif
    .ifndef PADS_ISO
        .equ PADS_ISO,                (1 << 8)
    .endif

@ DRIVE strength encoded values (datasheet sec 9.3.1 PADS_BANK0_GPIOn.DRIVE)
    .equ PADS_DRIVE_2MA,              (0 << 4)
    .equ PADS_DRIVE_4MA,              (1 << 4)
    .equ PADS_DRIVE_8MA,              (2 << 4)
    .equ PADS_DRIVE_12MA,             (3 << 4)

@ ---- PADS_QSPI (datasheet sec 9.3.2) ---------------------------------------
@   Per-pad layout matches PADS_BANK0:
@     +0x00  VOLTAGE_SELECT
@     +0x04  GPIO_QSPI_SCLK
@     +0x08  GPIO_QSPI_SD0
@     +0x0C  GPIO_QSPI_SD1
@     +0x10  GPIO_QSPI_SD2
@     +0x14  GPIO_QSPI_SD3
@     +0x18  GPIO_QSPI_SS
@   NOTE: the pad register order differs from the IO_QSPI ctrl order!
@   IO_QSPI uses {SCLK, SS, SD0..3}; PADS_QSPI uses {SCLK, SD0..3, SS}.
@   This index helper smooths over the difference.
    .equ PADS_QSPI_BASE,              0x40040000
    .equ PADS_QSPI_VOLTAGE_SELECT,    0x00
    .equ PADS_QSPI_GPIO_QSPI_SCLK,    0x04
    .equ PADS_QSPI_GPIO_QSPI_SD0,     0x08
    .equ PADS_QSPI_GPIO_QSPI_SD1,     0x0C
    .equ PADS_QSPI_GPIO_QSPI_SD2,     0x10
    .equ PADS_QSPI_GPIO_QSPI_SD3,     0x14
    .equ PADS_QSPI_GPIO_QSPI_SS,      0x18

@ Convenience composite values used by gpio_init / gpio_deinit.
@   IO|OD = 0x180  - pads start isolated and output-disabled at reset.
    .equ PADS_ISO_OD,                 (PADS_ISO | PADS_OD)
