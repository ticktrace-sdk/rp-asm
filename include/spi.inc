@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ spi.inc - RP2350 SPI (ARM PrimeCell PL022) register / bitfield definitions.
@   M4-G - communication peripherals milestone, agent G.
@
@ Datasheet refs:
@   * RP2350 datasheet rev 0.3 (Aug 2024) sec 12.3 (SPI), sec 7.5 (RESETS),
@     sec 3.2 (interrupt table).
@   * ARM PrimeCell SSP TRM (ARM DDI 0194H) - canonical PL022 register map.
@
@ The RP2350 instantiates two PL022 controllers ("SPI0", "SPI1").  Each
@ supports Motorola SPI (CPOL/CPHA configurable), TI synchronous Serial
@ Frame (SSF), and National Semiconductor Microwire frame formats with
@ 4..16 bit data words.  Both can run as master or slave, with optional
@ loopback (LBM) for self-test without external wiring.
@
@ Atomic register aliases (+0x1000 XOR / +0x2000 SET / +0x3000 CLR) apply
@ to PL022 registers - the RP2350 wraps every APB peripheral in the same
@ alias-window scheme.  See rp2350.inc for ATOMIC_*.
@ =============================================================================

@ ----- Bases (datasheet sec 2.2 memory map) ----------------------------------
    .equ SPI0_BASE,             0x40080000
    .equ SPI1_BASE,             0x40088000
    .equ SPI_INSTANCE_STRIDE,   0x00008000     @ SPI1 - SPI0 = 0x8000

@ ----- RESETS bit positions (datasheet sec 7.5) ------------------------------
@   These match the RP2350 numbering; older revs had spi0 at bit 17 - the
@   shipped silicon places spi0=18, spi1=19.  Cross-checked against the
@   pico-sdk hardware/regs/resets.h.
    .equ RESETS_spi0,           18
    .equ RESETS_spi1,           19

@ ----- NVIC IRQ lines (datasheet sec 3.2 interrupt table) --------------------
@   SPI0 = IRQ 31, SPI1 = IRQ 32 on RP2350.  (RP2040 had SPI0=18, SPI1=19;
@   the table was renumbered for RP2350.)
    .equ SPI0_IRQ,              31
    .equ SPI1_IRQ,              32

@ ----- PL022 register offsets (TRM table 3.1) --------------------------------
    .equ SSPCR0,                0x00       @ control register 0
    .equ SSPCR1,                0x04       @ control register 1
    .equ SSPDR,                 0x08       @ data register (TX/RX FIFO mux)
    .equ SSPSR,                 0x0C       @ status register
    .equ SSPCPSR,               0x10       @ clock prescale (CPSDVSR)
    .equ SSPIMSC,               0x14       @ interrupt mask set/clear
    .equ SSPRIS,                0x18       @ raw interrupt status
    .equ SSPMIS,                0x1C       @ masked interrupt status
    .equ SSPICR,                0x20       @ interrupt clear (W1C)
    .equ SSPDMACR,              0x24       @ DMA control

@ ----- SSPCR0 fields (TRM sec 3.4) -------------------------------------------
@   [3:0]   DSS    data size select - DSS+1 bits per word (0x3..0xF -> 4..16)
@   [5:4]   FRF    frame format (0=Motorola, 1=TI SSF, 2=National Microwire)
@   [6]     SPO    SCK polarity (Motorola only; CPOL)
@   [7]     SPH    SCK phase    (Motorola only; CPHA)
@   [15:8]  SCR    serial clock rate divider (effective = CPSDVSR*(1+SCR))
    .equ SSPCR0_DSS_LSB,        0
    .equ SSPCR0_DSS_MASK,       0x000F
    .equ SSPCR0_FRF_LSB,        4
    .equ SSPCR0_FRF_MASK,       0x0030
    .equ SSPCR0_SPO_LSB,        6
    .equ SSPCR0_SPO,            (1 << 6)
    .equ SSPCR0_SPH_LSB,        7
    .equ SSPCR0_SPH,            (1 << 7)
    .equ SSPCR0_SCR_LSB,        8
    .equ SSPCR0_SCR_MASK,       0xFF00

@   FRF encodings (shifted into bits [5:4])
    .equ SPI_FRF_MOTOROLA,      (0 << 4)
    .equ SPI_FRF_TI_SSI,        (1 << 4)
    .equ SPI_FRF_NS_MICROWIRE,  (2 << 4)

@   DSS encodings: data_bits-1 in bits [3:0].  Helpers for the common widths.
    .equ SPI_DSS_4,             (4  - 1)
    .equ SPI_DSS_8,             (8  - 1)
    .equ SPI_DSS_16,            (16 - 1)

@ ----- SSPCR1 fields (TRM sec 3.5) -------------------------------------------
@   [0]   LBM   loopback mode (output of TX serialiser fed back to RX)
@   [1]   SSE   serial port enable
@   [2]   MS    master/slave select (0 = master, 1 = slave)
@   [3]   SOD   slave-mode output disable (slave only)
    .equ SSPCR1_LBM_LSB,        0
    .equ SSPCR1_LBM,            (1 << 0)
    .equ SSPCR1_SSE_LSB,        1
    .equ SSPCR1_SSE,            (1 << 1)
    .equ SSPCR1_MS_LSB,         2
    .equ SSPCR1_MS,             (1 << 2)
    .equ SSPCR1_SOD_LSB,        3
    .equ SSPCR1_SOD,            (1 << 3)

@ ----- SSPSR fields (TRM sec 3.7) --------------------------------------------
@   [0]   TFE   TX FIFO empty
@   [1]   TNF   TX FIFO not full
@   [2]   RNE   RX FIFO not empty
@   [3]   RFF   RX FIFO full
@   [4]   BSY   busy (sending or receiving frames, or TX FIFO non-empty)
    .equ SSPSR_TFE_LSB,         0
    .equ SSPSR_TFE,             (1 << 0)
    .equ SSPSR_TNF_LSB,         1
    .equ SSPSR_TNF,             (1 << 1)
    .equ SSPSR_RNE_LSB,         2
    .equ SSPSR_RNE,             (1 << 2)
    .equ SSPSR_RFF_LSB,         3
    .equ SSPSR_RFF,             (1 << 3)
    .equ SSPSR_BSY_LSB,         4
    .equ SSPSR_BSY,             (1 << 4)

@ ----- SSPCPSR (clock prescale) ----------------------------------------------
@   [7:0]  CPSDVSR - even number 2..254.  effective_clock = clk_peri /
@                    (CPSDVSR * (1 + SCR)).  Bit 0 must be zero.
    .equ SSPCPSR_CPSDVSR_MASK,  0x00FE

@ ----- SSPIMSC / SSPRIS / SSPMIS / SSPICR ------------------------------------
@   [0]   RORIM  receive overrun interrupt
@   [1]   RTIM   receive timeout interrupt (no SCK for 32 cycles, RX FIFO !empty)
@   [2]   RXIM   RX FIFO half-full+ interrupt
@   [3]   TXIM   TX FIFO half-empty+ interrupt
@
@   SSPICR is W1C and only RORIC/RTIC bits exist (the FIFO interrupts are
@   level-driven and self-clear when the threshold is no longer met).
    .equ SSPIMSC_RORIM_LSB,     0
    .equ SSPIMSC_RORIM,         (1 << 0)
    .equ SSPIMSC_RTIM_LSB,      1
    .equ SSPIMSC_RTIM,          (1 << 1)
    .equ SSPIMSC_RXIM_LSB,      2
    .equ SSPIMSC_RXIM,          (1 << 2)
    .equ SSPIMSC_TXIM_LSB,      3
    .equ SSPIMSC_TXIM,          (1 << 3)
    .equ SSPIMSC_ALL,           (SSPIMSC_RORIM | SSPIMSC_RTIM | SSPIMSC_RXIM | SSPIMSC_TXIM)

@   SSPICR write-1-to-clear bits
    .equ SSPICR_RORIC,          (1 << 0)
    .equ SSPICR_RTIC,           (1 << 1)

@ ----- SSPDMACR --------------------------------------------------------------
@   [0]   RXDMAE   RX DMA enable (DREQ asserts on RX FIFO half-full+)
@   [1]   TXDMAE   TX DMA enable (DREQ asserts on TX FIFO half-empty+)
    .equ SSPDMACR_RXDMAE_LSB,   0
    .equ SSPDMACR_RXDMAE,       (1 << 0)
    .equ SSPDMACR_TXDMAE_LSB,   1
    .equ SSPDMACR_TXDMAE,       (1 << 1)
    .equ SSPDMACR_BOTH,         (SSPDMACR_RXDMAE | SSPDMACR_TXDMAE)

@ ----- DREQ codes (cross-check against include/dma.inc DREQ_SPI*) ------------
@   The dma.inc TREQ table lists:
@     DREQ_SPI0_TX = 24, DREQ_SPI0_RX = 25
@     DREQ_SPI1_TX = 26, DREQ_SPI1_RX = 27
@   Re-exposed here so SPI users can include only spi.inc.
    .equ SPI_DREQ_TX_OFFS,      0     @ relative to SPI*_DREQ_BASE
    .equ SPI_DREQ_RX_OFFS,      1
    .equ SPI0_DREQ_BASE,        24
    .equ SPI1_DREQ_BASE,        26
    .equ SPI0_TX_TREQ,          (SPI0_DREQ_BASE + SPI_DREQ_TX_OFFS)   @ 24
    .equ SPI0_RX_TREQ,          (SPI0_DREQ_BASE + SPI_DREQ_RX_OFFS)   @ 25
    .equ SPI1_TX_TREQ,          (SPI1_DREQ_BASE + SPI_DREQ_TX_OFFS)   @ 26
    .equ SPI1_RX_TREQ,          (SPI1_DREQ_BASE + SPI_DREQ_RX_OFFS)   @ 27

@ ----- GPIO function selector (datasheet table 597) --------------------------
@   FUNCSEL = 1 routes a pin to its SPI muxed function.  Already exposed in
@   include/gpio.inc as GPIO_FUNC_SPI; redefined here under an .ifndef so
@   spi.inc can be used standalone.
    .ifndef GPIO_FUNC_SPI
        .equ GPIO_FUNC_SPI,     1
    .endif
    .ifndef GPIO_FUNC_SIO
        .equ GPIO_FUNC_SIO,     5
    .endif

@ ----- FIFO depth ------------------------------------------------------------
@   PL022 has an 8-entry deep TX FIFO and 8-entry deep RX FIFO (TRM sec 1.2).
    .equ SPI_FIFO_DEPTH,        8

@ ----- Convenience pre-built CR0 word for common configs ---------------------
@   8-bit, Motorola, CPOL=0, CPHA=0, SCR=0 (SCR is set by spi_set_baudrate).
    .equ SPI_CR0_DEFAULT_8BIT,  (SPI_DSS_8 | SPI_FRF_MOTOROLA)

@ ----- Convenience pre-built CR1 word ----------------------------------------
@   Master, SSE off (so caller can OR SSE in last after CR0 + CPSR are set).
    .equ SPI_CR1_MASTER_OFF,    0
    .equ SPI_CR1_SLAVE_OFF,     SSPCR1_MS
