@ =============================================================================
@ uart.inc - RP2350 UART (ARM PL011 r1p5) register / bitfield definitions.
@
@ Datasheet ref: RP2350 datasheet rev 0.3 (Aug 2024) section 12.1.
@ Programmer's reference: ARM PrimeCell UART (PL011) Tech Ref. Manual r1p5
@ (DDI 0183G), since the RP2350 PL011 implementation matches that revision
@ verbatim plus a TX/RX DMA pacing extension.
@
@ This file is `.include`-d alongside rp2350.inc; it intentionally avoids
@ redefining symbols already in rp2350.inc (UART0_BASE, UART_DR, UART_FR,
@ UART_IBRD, UART_FBRD, UART_LCR_H, UART_CR, UART_FR_TXFF, UART_FR_RXFE,
@ UART_FR_BUSY).  The v0.1 driver only used those; the full M4-E driver
@ needs the rest of the register map and bitfield masks below.
@
@ NVIC IRQ numbers (RP2350 datasheet sec 3.2 table 3.1):
@   UART0_IRQ = 33
@   UART1_IRQ = 34
@
@ RESETS bits (rp2350.inc has uart0=26 already; uart1=27 added here).
@
@ Atomic register aliases (+0x1000 XOR / +0x2000 SET / +0x3000 CLR) apply.
@ =============================================================================

@ ---- Per-instance bases -----------------------------------------------------
@   UART0_BASE is in rp2350.inc.  We mirror it here for completeness and add
@   UART1_BASE.  Both blocks have an identical PL011 register layout.
    .ifndef UART0_BASE
        .equ UART0_BASE,            0x40070000
    .endif
    .equ UART1_BASE,                0x40078000
    .equ UART_INST_STRIDE,          (UART1_BASE - UART0_BASE)   @ 0x8000

@ ---- RESETS bit position for UART1 ------------------------------------------
@   rp2350.inc defines RESETS_uart0 = 26.
    .equ RESETS_uart1,              27

@ ---- NVIC IRQ numbers --------------------------------------------------------
    .equ UART0_IRQ,                 33
    .equ UART1_IRQ,                 34

@ ---- PL011 register offsets (datasheet sec 12.1.4) --------------------------
@   UART_DR / UART_FR / UART_IBRD / UART_FBRD / UART_LCR_H / UART_CR are
@   already defined in rp2350.inc; redefine guarded so this header can also
@   be used stand-alone.
    .ifndef UART_DR
        .equ UART_DR,               0x00    @ data register (low 8b = byte;
                                            @  upper bits are RX status)
    .endif
    .equ UART_RSR,                  0x04    @ RX status / error clear
    .ifndef UART_FR
        .equ UART_FR,               0x18    @ flag register (RO)
    .endif
    .equ UART_ILPR,                 0x20    @ IrDA low-power counter
    .ifndef UART_IBRD
        .equ UART_IBRD,             0x24    @ integer baud divisor (16b)
    .endif
    .ifndef UART_FBRD
        .equ UART_FBRD,             0x28    @ fractional baud divisor (6b)
    .endif
    .ifndef UART_LCR_H
        .equ UART_LCR_H,            0x2C    @ line control
    .endif
    .ifndef UART_CR
        .equ UART_CR,               0x30    @ control
    .endif
    .equ UART_IFLS,                 0x34    @ interrupt FIFO level select
    .equ UART_IMSC,                 0x38    @ interrupt mask set/clear
    .equ UART_RIS,                  0x3C    @ raw interrupt status (RO)
    .equ UART_MIS,                  0x40    @ masked interrupt status (RO)
    .equ UART_ICR,                  0x44    @ interrupt clear (W1C)
    .equ UART_DMACR,                0x48    @ DMA control

@ ---- UART_DR fields ---------------------------------------------------------
@   [7:0]    DATA
@   [8]      FE   (framing error, this byte)
@   [9]      PE   (parity error)
@   [10]     BE   (break error)
@   [11]     OE   (overrun error)
    .equ UART_DR_DATA_MASK,         0xFF
    .equ UART_DR_FE,                (1 << 8)
    .equ UART_DR_PE,                (1 << 9)
    .equ UART_DR_BE,                (1 << 10)
    .equ UART_DR_OE,                (1 << 11)

@ ---- UART_FR fields (RO; default 0x90 = TXFE|RXFE post-reset) --------------
@   [0]   CTS    1 = nUARTCTS is asserted (active-low input low)
@   [1]   DSR    (unused on RP2350; tied 0)
@   [2]   DCD    (unused; tied 0)
@   [3]   BUSY   1 = UART is currently transmitting (FIFO non-empty or shift reg busy)
@   [4]   RXFE   1 = RX FIFO empty
@   [5]   TXFF   1 = TX FIFO full
@   [6]   RXFF   1 = RX FIFO full
@   [7]   TXFE   1 = TX FIFO empty
@   [8]   RI     (unused; tied 0)
    .equ UART_FR_CTS,               (1 << 0)
    .equ UART_FR_DSR,               (1 << 1)
    .equ UART_FR_DCD,               (1 << 2)
    .ifndef UART_FR_BUSY
        .equ UART_FR_BUSY,          (1 << 3)
    .endif
    .ifndef UART_FR_RXFE
        .equ UART_FR_RXFE,          (1 << 4)
    .endif
    .ifndef UART_FR_TXFF
        .equ UART_FR_TXFF,          (1 << 5)
    .endif
    .equ UART_FR_RXFF,              (1 << 6)
    .equ UART_FR_TXFE,              (1 << 7)
    .equ UART_FR_RI,                (1 << 8)

@ ---- UART_LCR_H fields (line control) ---------------------------------------
@   [0]      BRK    send break (continuous low while set)
@   [1]      PEN    parity enable
@   [2]      EPS    even parity select (0 = odd, 1 = even); valid when PEN=1
@   [3]      STP2   2 stop bits
@   [4]      FEN    FIFO enable (16 deep when on; 1 deep when off)
@   [6:5]    WLEN   word length: 0=5b, 1=6b, 2=7b, 3=8b
@   [7]      SPS    stick parity select (rare; 0 for normal use)
    .equ UART_LCR_H_BRK,            (1 << 0)
    .equ UART_LCR_H_PEN,            (1 << 1)
    .equ UART_LCR_H_EPS,            (1 << 2)
    .equ UART_LCR_H_STP2,           (1 << 3)
    .equ UART_LCR_H_FEN,            (1 << 4)
    .equ UART_LCR_H_WLEN_LSB,       5
    .equ UART_LCR_H_WLEN_MASK,      (3 << 5)
    .equ UART_LCR_H_WLEN_5,         (0 << 5)
    .equ UART_LCR_H_WLEN_6,         (1 << 5)
    .equ UART_LCR_H_WLEN_7,         (2 << 5)
    .equ UART_LCR_H_WLEN_8,         (3 << 5)
    .equ UART_LCR_H_SPS,            (1 << 7)

@ ---- UART_CR fields (control) -----------------------------------------------
@   [0]      UARTEN   master enable
@   [1]      SIREN    IrDA SIR enable
@   [2]      SIRLP    IrDA low-power
@   [7]      LBE      loopback enable (TX -> RX internally)
@   [8]      TXE      transmit enable
@   [9]      RXE      receive enable
@   [10]     DTR      data-transmit-ready output (active when 1; nDTR pin low)
@   [11]     RTS      request-to-send output (active when 1; nRTS pin low)
@   [12]     OUT1     general-purpose output 1
@   [13]     OUT2     general-purpose output 2
@   [14]     RTSEN    RTS hardware flow-control enable
@   [15]     CTSEN    CTS hardware flow-control enable
    .equ UART_CR_UARTEN,            (1 << 0)
    .equ UART_CR_SIREN,             (1 << 1)
    .equ UART_CR_SIRLP,             (1 << 2)
    .equ UART_CR_LBE,               (1 << 7)
    .equ UART_CR_TXE,               (1 << 8)
    .equ UART_CR_RXE,               (1 << 9)
    .equ UART_CR_DTR,               (1 << 10)
    .equ UART_CR_RTS,               (1 << 11)
    .equ UART_CR_OUT1,              (1 << 12)
    .equ UART_CR_OUT2,              (1 << 13)
    .equ UART_CR_RTSEN,             (1 << 14)
    .equ UART_CR_CTSEN,             (1 << 15)

@ ---- UART_IFLS fields (interrupt FIFO level select) ------------------------
@   [2:0]    TXIFLSEL   TX FIFO trigger:  0=1/8, 1=1/4, 2=1/2, 3=3/4, 4=7/8
@   [5:3]    RXIFLSEL   RX FIFO trigger:  same encoding
@   Reset value 0x12 = TX 1/2, RX 1/2.
    .equ UART_IFLS_TXIFLSEL_LSB,    0
    .equ UART_IFLS_RXIFLSEL_LSB,    3
    .equ UART_IFLS_LEVEL_1_8,       0
    .equ UART_IFLS_LEVEL_1_4,       1
    .equ UART_IFLS_LEVEL_1_2,       2
    .equ UART_IFLS_LEVEL_3_4,       3
    .equ UART_IFLS_LEVEL_7_8,       4

@ ---- UART_IMSC / RIS / MIS / ICR bit positions (datasheet sec 12.1.4) ------
@   [0]   RI    nUARTRI modem (unused on RP2350)
@   [1]   CTS   nUARTCTS modem
@   [2]   DCD   nUARTDCD modem (unused)
@   [3]   DSR   nUARTDSR modem (unused)
@   [4]   RX    RX trigger crossed (>= IFLS.RXIFLSEL)
@   [5]   TX    TX trigger crossed (<= IFLS.TXIFLSEL)
@   [6]   RT    RX timeout (32-bit periods of idle line w/ data still in FIFO)
@   [7]   FE    framing error
@   [8]   PE    parity error
@   [9]   BE    break error
@   [10]  OE    overrun error
    .equ UART_INT_RI_LSB,           0
    .equ UART_INT_CTS_LSB,          1
    .equ UART_INT_DCD_LSB,          2
    .equ UART_INT_DSR_LSB,          3
    .equ UART_INT_RX_LSB,           4
    .equ UART_INT_TX_LSB,           5
    .equ UART_INT_RT_LSB,           6
    .equ UART_INT_FE_LSB,           7
    .equ UART_INT_PE_LSB,           8
    .equ UART_INT_BE_LSB,           9
    .equ UART_INT_OE_LSB,          10

    .equ UART_INT_RIM,              (1 << 0)
    .equ UART_INT_CTSM,             (1 << 1)
    .equ UART_INT_DCDM,             (1 << 2)
    .equ UART_INT_DSRM,             (1 << 3)
    .equ UART_INT_RXIM,             (1 << 4)
    .equ UART_INT_TXIM,             (1 << 5)
    .equ UART_INT_RTIM,             (1 << 6)
    .equ UART_INT_FEIM,             (1 << 7)
    .equ UART_INT_PEIM,             (1 << 8)
    .equ UART_INT_BEIM,             (1 << 9)
    .equ UART_INT_OEIM,             (1 << 10)
    .equ UART_INT_ALL,              0x7FF

@ ---- UART_DMACR fields ------------------------------------------------------
@   [0]   RXDMAE   RX DMA enable (DREQ_UART<n>_RX active when RX FIFO has data)
@   [1]   TXDMAE   TX DMA enable (DREQ_UART<n>_TX active when TX FIFO has space)
@   [2]   DMAONERR DMA disable on RX error (auto-clears RXDMAE on FE/PE/BE/OE)
    .equ UART_DMACR_RXDMAE,         (1 << 0)
    .equ UART_DMACR_TXDMAE,         (1 << 1)
    .equ UART_DMACR_DMAONERR,       (1 << 2)

@ ---- Baud divisor pre-computed constants -----------------------------------
@   IBRD = floor(clk_peri / (16 * baud))
@   FBRD = round((clk_peri / (16 * baud) - IBRD) * 64)
@
@   12 MHz column matches v0.1's clk_peri = 12 MHz pass-through (XOSC direct);
@   150 MHz column matches M2's clk_peri = 150 MHz from PLL_SYS / 1.
@
@   12 MHz / 16 / 115200 = 6.5104  -> IBRD=6,  FBRD=33
@   12 MHz / 16 / 230400 = 3.2552  -> IBRD=3,  FBRD=16
@   12 MHz / 16 / 460800 = 1.6276  -> IBRD=1,  FBRD=40
@   12 MHz / 16 / 921600 = 0.8138  -> IBRD=0 INVALID (< 1) - skip 921600 @ 12 MHz
@
@   150 MHz / 16 / 115200  = 81.380  -> IBRD=81, FBRD=24
@   150 MHz / 16 / 230400  = 40.690  -> IBRD=40, FBRD=44
@   150 MHz / 16 / 460800  = 20.345  -> IBRD=20, FBRD=22
@   150 MHz / 16 / 921600  = 10.172  -> IBRD=10, FBRD=11
@   150 MHz / 16 / 1000000 =  9.375  -> IBRD=9,  FBRD=24
    .equ UART_IBRD_12MHZ_115200,    6
    .equ UART_FBRD_12MHZ_115200,    33
    .equ UART_IBRD_12MHZ_230400,    3
    .equ UART_FBRD_12MHZ_230400,    16
    .equ UART_IBRD_12MHZ_460800,    1
    .equ UART_FBRD_12MHZ_460800,    40

    .ifndef UART_IBRD_150MHZ
        .equ UART_IBRD_150MHZ,      81
    .endif
    .ifndef UART_FBRD_150MHZ
        .equ UART_FBRD_150MHZ,      24
    .endif
    .equ UART_IBRD_150MHZ_115200,   81
    .equ UART_FBRD_150MHZ_115200,   24
    .equ UART_IBRD_150MHZ_230400,   40
    .equ UART_FBRD_150MHZ_230400,   44
    .equ UART_IBRD_150MHZ_460800,   20
    .equ UART_FBRD_150MHZ_460800,   22
    .equ UART_IBRD_150MHZ_921600,   10
    .equ UART_FBRD_150MHZ_921600,   11
    .equ UART_IBRD_150MHZ_1000000,  9
    .equ UART_FBRD_150MHZ_1000000,  24

@ ---- Default pin assignments ------------------------------------------------
@   The RP2350 SDK convention: UART0 on GP0 (TX) / GP1 (RX); UART1 on
@   GP4 (TX) / GP5 (RX).  RTS/CTS, when used, sit immediately after RX.
    .equ UART0_DEFAULT_TX_PIN,      0
    .equ UART0_DEFAULT_RX_PIN,      1
    .equ UART0_DEFAULT_CTS_PIN,     2
    .equ UART0_DEFAULT_RTS_PIN,     3
    .equ UART1_DEFAULT_TX_PIN,      4
    .equ UART1_DEFAULT_RX_PIN,      5
    .equ UART1_DEFAULT_CTS_PIN,     6
    .equ UART1_DEFAULT_RTS_PIN,     7
