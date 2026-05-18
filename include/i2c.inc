@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ i2c.inc - RP2350 DesignWare DW_apb_i2c register / bitfield definitions (M4-F)
@
@ The RP2350 has TWO instances of the Synopsys DesignWare APB I2C controller
@ (same peripheral as on the RP2040).  Both bases share an identical register
@ layout - the driver in src/i2c.S parameterises by an "idx" of 0 or 1 and
@ derives the base via I2C0_BASE + idx * (I2C1_BASE - I2C0_BASE).
@
@ Datasheet ref: RP2350 datasheet rev 0.3 (Aug 2024) sec 12.4 (I2C).  Most
@ register documentation lives in the upstream DesignWare DW_apb_i2c
@ databook; the RP2350 chapter only documents the wiring (resets, IRQs,
@ DREQs, GPIO function code).
@
@ Atomic register aliases (+0x1000 XOR / +0x2000 SET / +0x3000 CLR) apply
@ to most fields; in practice the only ones we use are plain RW, since the
@ DesignWare semantics already provide a "self-clearing" pattern via
@ IC_CLR_INTR / IC_CLR_<reason> and W1C-on-status registers.
@
@ Important gotcha: most config registers are R/O while IC_ENABLE = 1.
@ The init sequence is therefore strictly:
@   1. clear IC_ENABLE (write 0)
@   2. program IC_CON, IC_TAR, SCL counts, SDA hold, etc.
@   3. set IC_ENABLE (write 1)
@ A sloppy second-pass write to IC_CON without first dropping IC_ENABLE is
@ silently ignored.
@ =============================================================================

@ ----- Top-level bases -------------------------------------------------------
    .equ I2C0_BASE,                 0x40090000
    .equ I2C1_BASE,                 0x40098000
    .equ I2C_INSTANCE_STRIDE,       (I2C1_BASE - I2C0_BASE)   @ = 0x8000

@ ----- Per-instance register offsets (relative to instance base) -------------
@   Synopsys DW_apb_i2c v2.01.  Offsets verified against Pico SDK headers.
    .equ IC_CON,                    0x00
    .equ IC_TAR,                    0x04
    .equ IC_SAR,                    0x08
    .equ IC_DATA_CMD,               0x10
    .equ IC_SS_SCL_HCNT,            0x14
    .equ IC_SS_SCL_LCNT,            0x18
    .equ IC_FS_SCL_HCNT,            0x1C
    .equ IC_FS_SCL_LCNT,            0x20
    .equ IC_INTR_STAT,              0x2C
    .equ IC_INTR_MASK,              0x30
    .equ IC_RAW_INTR_STAT,          0x34
    .equ IC_RX_TL,                  0x38
    .equ IC_TX_TL,                  0x3C
    .equ IC_CLR_INTR,               0x40
    .equ IC_CLR_RX_UNDER,           0x44
    .equ IC_CLR_RX_OVER,            0x48
    .equ IC_CLR_TX_OVER,            0x4C
    .equ IC_CLR_RD_REQ,             0x50
    .equ IC_CLR_TX_ABRT,            0x54
    .equ IC_CLR_RX_DONE,            0x58
    .equ IC_CLR_ACTIVITY,           0x5C
    .equ IC_CLR_STOP_DET,           0x60
    .equ IC_CLR_START_DET,          0x64
    .equ IC_ENABLE,                 0x6C
    .equ IC_STATUS,                 0x70
    .equ IC_TXFLR,                  0x74
    .equ IC_RXFLR,                  0x78
    .equ IC_SDA_HOLD,               0x7C
    .equ IC_TX_ABRT_SOURCE,         0x80
    .equ IC_DMA_CR,                 0x88
    .equ IC_DMA_TDLR,               0x8C
    .equ IC_DMA_RDLR,               0x90
    .equ IC_ENABLE_STATUS,          0x9C
    .equ IC_FS_SPKLEN,              0xA0

@ ----- IC_CON bit positions (DW databook §3.3.1) -----------------------------
@   [0]   MASTER_MODE
@   [2:1] SPEED   (1=Standard 100 kHz, 2=Fast 400 kHz / Fast+ 1 MHz, 3=High)
@   [3]   IC_10BITADDR_SLAVE
@   [4]   IC_10BITADDR_MASTER
@   [5]   IC_RESTART_EN
@   [6]   IC_SLAVE_DISABLE
@   [7]   STOP_DET_IFADDRESSED
@   [8]   TX_EMPTY_CTRL  (TX_EMPTY fires when both FIFO is empty AND
@                          shifter has finished - safer than FIFO-only)
@   [9]   RX_FIFO_FULL_HLD_CTRL
    .equ IC_CON_MASTER_MODE_LSB,            0
    .equ IC_CON_SPEED_LSB,                  1
    .equ IC_CON_IC_10BITADDR_SLAVE_LSB,     3
    .equ IC_CON_IC_10BITADDR_MASTER_LSB,    4
    .equ IC_CON_IC_RESTART_EN_LSB,          5
    .equ IC_CON_IC_SLAVE_DISABLE_LSB,       6
    .equ IC_CON_STOP_DET_IFADDRESSED_LSB,   7
    .equ IC_CON_TX_EMPTY_CTRL_LSB,          8
    .equ IC_CON_RX_FIFO_FULL_HLD_CTRL_LSB,  9

    .equ IC_CON_MASTER_MODE,                (1 << 0)
    .equ IC_CON_IC_10BITADDR_SLAVE,         (1 << 3)
    .equ IC_CON_IC_10BITADDR_MASTER,        (1 << 4)
    .equ IC_CON_IC_RESTART_EN,              (1 << 5)
    .equ IC_CON_IC_SLAVE_DISABLE,           (1 << 6)
    .equ IC_CON_STOP_DET_IFADDRESSED,       (1 << 7)
    .equ IC_CON_TX_EMPTY_CTRL,              (1 << 8)
    .equ IC_CON_RX_FIFO_FULL_HLD_CTRL,      (1 << 9)

    @ SPEED encodings (shifted into [2:1])
    .equ IC_CON_SPEED_SS,                   (1 << 1)
    .equ IC_CON_SPEED_FS,                   (2 << 1)
    .equ IC_CON_SPEED_HS,                   (3 << 1)

    @ Canned MASTER + Fast Speed config used by i2c_init.  Caller adds
    @ 10-bit-master if needed.  RESTART_EN required for i2c_write_blocking
    @ with nostop=0 followed by a read.  TX_EMPTY_CTRL keeps TX_EMPTY from
    @ firing while a byte is still being shifted out (datasheet §3.3.1).
    .equ I2C_CON_MASTER_FS, (IC_CON_MASTER_MODE | IC_CON_SPEED_FS | IC_CON_IC_RESTART_EN | IC_CON_IC_SLAVE_DISABLE | IC_CON_TX_EMPTY_CTRL)
    .equ I2C_CON_MASTER_SS, (IC_CON_MASTER_MODE | IC_CON_SPEED_SS | IC_CON_IC_RESTART_EN | IC_CON_IC_SLAVE_DISABLE | IC_CON_TX_EMPTY_CTRL)

    @ Slave-mode CON: clear MASTER_MODE + SLAVE_DISABLE.  SPEED still set
    @ so the input-glitch filter matches what the bus is doing.
    .equ I2C_CON_SLAVE_FS,  (IC_CON_SPEED_FS | IC_CON_IC_RESTART_EN | IC_CON_TX_EMPTY_CTRL)

@ ----- IC_DATA_CMD bit positions ---------------------------------------------
@   [7:0] DAT      data byte (write) or RX byte (read)
@   [8]   CMD      0 = write to slave, 1 = read from slave (issued by master)
@   [9]   STOP     1 = issue STOP after this byte
@   [10]  RESTART  1 = issue RESTART before this byte
@   [11]  FIRST_DATA_BYTE  (RO; driver does not use)
    .equ IC_DATA_CMD_DAT_MASK,      0xFF
    .equ IC_DATA_CMD_CMD_LSB,       8
    .equ IC_DATA_CMD_STOP_LSB,      9
    .equ IC_DATA_CMD_RESTART_LSB,   10

    .equ IC_DATA_CMD_CMD,           (1 << 8)        @ 1 = read
    .equ IC_DATA_CMD_STOP,          (1 << 9)
    .equ IC_DATA_CMD_RESTART,       (1 << 10)

@ ----- IC_INTR_STAT / IC_INTR_MASK / IC_RAW_INTR_STAT bit positions ----------
@   Common bits we wire up:
    .equ IC_INTR_RX_UNDER,          (1 << 0)
    .equ IC_INTR_RX_OVER,           (1 << 1)
    .equ IC_INTR_RX_FULL,           (1 << 2)
    .equ IC_INTR_TX_OVER,           (1 << 3)
    .equ IC_INTR_TX_EMPTY,          (1 << 4)
    .equ IC_INTR_RD_REQ,            (1 << 5)
    .equ IC_INTR_TX_ABRT,           (1 << 6)
    .equ IC_INTR_RX_DONE,           (1 << 7)
    .equ IC_INTR_ACTIVITY,          (1 << 8)
    .equ IC_INTR_STOP_DET,          (1 << 9)
    .equ IC_INTR_START_DET,         (1 << 10)
    .equ IC_INTR_GEN_CALL,          (1 << 11)
    .equ IC_INTR_RESTART_DET,       (1 << 12)

@ ----- IC_STATUS bit positions -----------------------------------------------
@   [0]  ACTIVITY    activity detected on the bus
@   [1]  TFNF        TX FIFO Not Full  -- can write IC_DATA_CMD
@   [2]  TFE         TX FIFO Empty
@   [3]  RFNE        RX FIFO Not Empty -- can read IC_DATA_CMD
@   [4]  RFF         RX FIFO Full
@   [5]  MST_ACTIVITY  master FSM not idle
@   [6]  SLV_ACTIVITY  slave FSM not idle
    .equ IC_STATUS_ACTIVITY,        (1 << 0)
    .equ IC_STATUS_TFNF,            (1 << 1)
    .equ IC_STATUS_TFE,             (1 << 2)
    .equ IC_STATUS_RFNE,            (1 << 3)
    .equ IC_STATUS_RFF,             (1 << 4)
    .equ IC_STATUS_MST_ACTIVITY,    (1 << 5)
    .equ IC_STATUS_SLV_ACTIVITY,    (1 << 6)

@ ----- IC_ENABLE bits --------------------------------------------------------
    .equ IC_ENABLE_ENABLE,          (1 << 0)
    .equ IC_ENABLE_ABORT,           (1 << 1)

@ ----- IC_DMA_CR bits --------------------------------------------------------
    .equ IC_DMA_CR_RDMAE,           (1 << 0)        @ RX DMA enable
    .equ IC_DMA_CR_TDMAE,           (1 << 1)        @ TX DMA enable

@ ----- RESETS bit positions (datasheet §7.5) ---------------------------------
    .equ RESETS_i2c0,               4
    .equ RESETS_i2c1,               5

@ ----- NVIC IRQ lines (datasheet §3.2.1, RP2350 IRQ table) -------------------
@   I2C0 = 35, I2C1 = 36 (verify on your board's silicon revision)
    .equ I2C0_IRQ,                  35
    .equ I2C1_IRQ,                  36

@ ----- DREQ codes -------------------------------------------------------------
@   Note: include/dma.inc already defines DREQ_I2C0_TX = 40, DREQ_I2C0_RX = 41,
@   DREQ_I2C1_TX = 42, DREQ_I2C1_RX = 43.  We do NOT redefine them here so the
@   two headers can be included together without a symbol clash.

@ ----- Pre-computed SCL HCNT/LCNT for clk_peri = 150 MHz ---------------------
@   The runtime driver in src/i2c.S uses the formula
@       period_ticks = clk_peri / freq
@       HCNT = period_ticks * 4 / 10 - 8     (clamped >= 8)
@       LCNT = period_ticks * 6 / 10 - 1     (clamped >= 8)
@   Derivation in docs/i2c.md.  Tabulated for sanity / debug use:
@
@   freq          period_ticks   HCNT   LCNT   sum    SCL_actual
@   ----          ------------   ----   ----   ----   ----------
@   100 kHz       1500           592    899    1491   100.6 kHz
@   400 kHz        375           142    224     366   409.8 kHz
@   1   MHz        150            52     89     141   1064 kHz
@
@   These are >>= the I2C-bus spec minima (tHIGH/tLOW per 6.1) and < the
@   IC_FS_SPKLEN-induced upper bound of 65535.  All three speeds verified
@   to round-trip the busy-loop spin in tests/unicorn/test_i2c.py.
    .equ I2C_HCNT_100K_AT_150MHZ,   592
    .equ I2C_LCNT_100K_AT_150MHZ,   899
    .equ I2C_HCNT_400K_AT_150MHZ,   142
    .equ I2C_LCNT_400K_AT_150MHZ,   224
    .equ I2C_HCNT_1M_AT_150MHZ,     52
    .equ I2C_LCNT_1M_AT_150MHZ,     89

    .equ I2C_SDA_HOLD_FS_AT_150MHZ, 10      @ ~67 ns; spec wants >= 0 ns
    .equ I2C_SDA_HOLD_HS_AT_150MHZ, 4

    .equ I2C_FS_SPKLEN_DEFAULT,     2       @ glitch filter ~2 clk_peri ticks
