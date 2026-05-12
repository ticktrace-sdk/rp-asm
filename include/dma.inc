@ =============================================================================
@ dma.inc - RP2350 DMA controller register / bitfield definitions (M3-C).
@
@ Datasheet ref: RP2350 datasheet rev 0.3 (Aug 2024) section 12.6.
@
@ The DMA controller has:
@   - 16 channels, each with READ_ADDR/WRITE_ADDR/TRANS_COUNT/CTRL_TRIG +
@     three "alias" sets of those four registers.  The alias chosen by the
@     firmware controls which final write triggers the transfer (the alias
@     where TRIG/COUNT/etc. is the LAST register in the block).
@   - 4 IRQ aggregators (DMA_IRQ_0..3); each channel can be routed to any of
@     them via INTE0..INTE3.
@   - 4 pacing TIMERs, programmable as fractional dividers feeding the DREQ
@     mux as TIMER0..TIMER3 (TREQ codes 0x3B..0x3E).
@   - One sniffer / CRC engine with selectable polynomial (CRC16/32/EVEN/SUM).
@
@ Conventions (matching include/clocks.inc):
@   - DMA_BASE is an absolute byte address.
@   - DMA_CHn_* offsets are relative to DMA_BASE (channel block at +n*0x40).
@   - Per-register offsets within a channel are relative to the channel base.
@   - Bit positions are *_LSB; mask helpers are (n << *_LSB) or (1 << *_LSB).
@
@ The standard atomic alias windows (+0x1000 XOR / +0x2000 SET / +0x3000 CLR)
@ apply to the DMA controller too.
@ =============================================================================

@ ----- Top-level base / channel layout ---------------------------------------
    .equ DMA_BASE,              0x50000000
    .equ DMA_CHANNEL_STRIDE,    0x40        @ size of one per-channel block

@ ----- Per-channel register offsets (relative to channel base) ---------------
@   "AL0" is the 0x00 set; writing CTRL_TRIG (offset 0x0C) latches and
@   triggers.  "AL1" set has TRANS_COUNT_TRIG (offset 0x1C) as the trigger;
@   "AL2" set has READ_ADDR_TRIG (offset 0x2C) as the trigger; "AL3" set
@   has WRITE_ADDR_TRIG (offset 0x3C).  Pick the alias whose triggering
@   register is the one you want to write last.
    .equ DMA_CH_READ_ADDR,            0x00
    .equ DMA_CH_WRITE_ADDR,           0x04
    .equ DMA_CH_TRANS_COUNT,          0x08
    .equ DMA_CH_CTRL_TRIG,            0x0C
    .equ DMA_CH_AL1_CTRL,             0x10        @ CTRL only, no trigger
    .equ DMA_CH_AL1_READ_ADDR,        0x14
    .equ DMA_CH_AL1_WRITE_ADDR,       0x18
    .equ DMA_CH_AL1_TRANS_COUNT_TRIG, 0x1C        @ writing here triggers
    .equ DMA_CH_AL2_CTRL,             0x20
    .equ DMA_CH_AL2_TRANS_COUNT,      0x24
    .equ DMA_CH_AL2_READ_ADDR,        0x28
    .equ DMA_CH_AL2_WRITE_ADDR_TRIG,  0x2C        @ writing here triggers
    .equ DMA_CH_AL3_CTRL,             0x30
    .equ DMA_CH_AL3_WRITE_ADDR,       0x34
    .equ DMA_CH_AL3_TRANS_COUNT,      0x38
    .equ DMA_CH_AL3_READ_ADDR_TRIG,   0x3C        @ writing here triggers

@ ----- Global registers (offsets from DMA_BASE) ------------------------------
    .equ DMA_INTR,              0x400       @ raw interrupt status (W1C)
    .equ DMA_INTE0,             0x404       @ enable mask for IRQ aggregator 0
    .equ DMA_INTF0,             0x408       @ force bits for aggregator 0
    .equ DMA_INTS0,             0x40C       @ status (after enable + force) for 0
    .equ DMA_INTR1,             0x410       @ (alias of INTR; some docs name it)
    .equ DMA_INTE1,             0x414
    .equ DMA_INTF1,             0x418
    .equ DMA_INTS1,             0x41C
    .equ DMA_INTR2,             0x420
    .equ DMA_INTE2,             0x424
    .equ DMA_INTF2,             0x428
    .equ DMA_INTS2,             0x42C
    .equ DMA_INTR3,             0x430
    .equ DMA_INTE3,             0x434
    .equ DMA_INTF3,             0x438
    .equ DMA_INTS3,             0x43C

    @ Pacing timers (fractional dividers).  Each is one 32-bit register:
    @   [31:16] X (numerator), [15:0] Y (denominator); rate = clk_sys * X / Y.
    @ These four registers reuse the 0x420..0x42C window in the historical
    @ RP2040 layout; on RP2350 the IRQ aggregators are interleaved.  Use the
    @ explicit DMA_TIMER0..3 names below; on real silicon prefer the SDK
    @ sym names if you cross-check.
    .equ DMA_TIMER0,            0x420
    .equ DMA_TIMER1,            0x424
    .equ DMA_TIMER2,            0x428
    .equ DMA_TIMER3,            0x42C

    .equ DMA_MULTI_CHAN_TRIGGER,0x430       @ write 1<<n to trigger channel n
    .equ DMA_SNIFF_CTRL,        0x434
    .equ DMA_SNIFF_DATA,        0x438
    .equ DMA_FIFO_LEVELS,       0x440
    .equ DMA_CHAN_ABORT,        0x444       @ write 1<<n to abort channel n
    .equ DMA_N_CHANNELS,        0x448

    @ Per-channel debug block: CHn_DBG_CTDREQ at 0x800 + n*0x40
    .equ DMA_CH_DBG_BASE,       0x800
    .equ DMA_CH_DBG_STRIDE,     0x40
    .equ DMA_CH_DBG_CTDREQ,     0x00        @ remaining DREQ count
    .equ DMA_CH_DBG_TCR,        0x04        @ remaining transfer count

@ ----- CTRL bitfield (datasheet §12.6.2.4) -----------------------------------
@   [0]      EN
@   [1]      HIGH_PRIORITY
@   [3:2]    DATA_SIZE  (0=byte / 1=halfword / 2=word)
@   [4]      INCR_READ
@   [5]      INCR_READ_REV
@   [6]      INCR_WRITE
@   [7]      INCR_WRITE_REV
@   [11:8]   RING_SIZE   (0 = no wrap; otherwise wrap addr at 1<<RING_SIZE bytes)
@   [12]     RING_SEL    (0 = wrap READ_ADDR, 1 = wrap WRITE_ADDR)
@   [16:13]  CHAIN_TO    (channel index to chain to; set to self to disable)
@   [22:17]  TREQ_SEL    (0..63; see TREQ table below)
@   [23]     IRQ_QUIET
@   [24]     BSWAP
@   [25]     SNIFF_EN
@   [26]     BUSY        (RO)
@   [29]     READ_ERROR  (W1C)
@   [30]     WRITE_ERROR (W1C)
@   [31]     AHB_ERROR   (RO; OR of READ_ERROR | WRITE_ERROR)
    .equ DMA_CTRL_EN_LSB,             0
    .equ DMA_CTRL_HIGH_PRIORITY_LSB,  1
    .equ DMA_CTRL_DATA_SIZE_LSB,      2
    .equ DMA_CTRL_INCR_READ_LSB,      4
    .equ DMA_CTRL_INCR_READ_REV_LSB,  5
    .equ DMA_CTRL_INCR_WRITE_LSB,     6
    .equ DMA_CTRL_INCR_WRITE_REV_LSB, 7
    .equ DMA_CTRL_RING_SIZE_LSB,      8
    .equ DMA_CTRL_RING_SEL_LSB,       12
    .equ DMA_CTRL_CHAIN_TO_LSB,       13
    .equ DMA_CTRL_TREQ_SEL_LSB,       17
    .equ DMA_CTRL_IRQ_QUIET_LSB,      23
    .equ DMA_CTRL_BSWAP_LSB,          24
    .equ DMA_CTRL_SNIFF_EN_LSB,       25
    .equ DMA_CTRL_BUSY_LSB,           26
    .equ DMA_CTRL_READ_ERROR_LSB,     29
    .equ DMA_CTRL_WRITE_ERROR_LSB,    30
    .equ DMA_CTRL_AHB_ERROR_LSB,      31

    @ Single-bit masks
    .equ DMA_CTRL_EN,                 (1 << 0)
    .equ DMA_CTRL_HIGH_PRIORITY,      (1 << 1)
    .equ DMA_CTRL_INCR_READ,          (1 << 4)
    .equ DMA_CTRL_INCR_READ_REV,      (1 << 5)
    .equ DMA_CTRL_INCR_WRITE,         (1 << 6)
    .equ DMA_CTRL_INCR_WRITE_REV,     (1 << 7)
    .equ DMA_CTRL_RING_SEL,           (1 << 12)
    .equ DMA_CTRL_IRQ_QUIET,          (1 << 23)
    .equ DMA_CTRL_BSWAP,              (1 << 24)
    .equ DMA_CTRL_SNIFF_EN,           (1 << 25)
    .equ DMA_CTRL_BUSY,               (1 << 26)
    .equ DMA_CTRL_READ_ERROR,         (1 << 29)
    .equ DMA_CTRL_WRITE_ERROR,        (1 << 30)
    .equ DMA_CTRL_AHB_ERROR,          (1 << 31)

    @ DATA_SIZE encodings (shifted into [3:2])
    .equ DMA_DATA_SIZE_BYTE,          (0 << 2)
    .equ DMA_DATA_SIZE_HALFWORD,      (1 << 2)
    .equ DMA_DATA_SIZE_WORD,          (2 << 2)

@ ----- TREQ codes (shifted by callers using DMA_CTRL_TREQ_SEL_LSB) ----------
@   The full table from datasheet §12.6.4.  Field is 6 bits.
    .equ DREQ_PIO0_TX0,         0
    .equ DREQ_PIO0_TX1,         1
    .equ DREQ_PIO0_TX2,         2
    .equ DREQ_PIO0_TX3,         3
    .equ DREQ_PIO0_RX0,         4
    .equ DREQ_PIO0_RX1,         5
    .equ DREQ_PIO0_RX2,         6
    .equ DREQ_PIO0_RX3,         7
    .equ DREQ_PIO1_TX0,         8
    .equ DREQ_PIO1_TX1,         9
    .equ DREQ_PIO1_TX2,         10
    .equ DREQ_PIO1_TX3,         11
    .equ DREQ_PIO1_RX0,         12
    .equ DREQ_PIO1_RX1,         13
    .equ DREQ_PIO1_RX2,         14
    .equ DREQ_PIO1_RX3,         15
    .equ DREQ_PIO2_TX0,         16
    .equ DREQ_PIO2_TX1,         17
    .equ DREQ_PIO2_TX2,         18
    .equ DREQ_PIO2_TX3,         19
    .equ DREQ_PIO2_RX0,         20
    .equ DREQ_PIO2_RX1,         21
    .equ DREQ_PIO2_RX2,         22
    .equ DREQ_PIO2_RX3,         23
    .equ DREQ_SPI0_TX,          24
    .equ DREQ_SPI0_RX,          25
    .equ DREQ_SPI1_TX,          26
    .equ DREQ_SPI1_RX,          27
    .equ DREQ_UART0_TX,         28
    .equ DREQ_UART0_RX,         29
    .equ DREQ_UART1_TX,         30
    .equ DREQ_UART1_RX,         31
    .equ DREQ_PWM_WRAP0,        32
    .equ DREQ_PWM_WRAP1,        33
    .equ DREQ_PWM_WRAP2,        34
    .equ DREQ_PWM_WRAP3,        35
    .equ DREQ_PWM_WRAP4,        36
    .equ DREQ_PWM_WRAP5,        37
    .equ DREQ_PWM_WRAP6,        38
    .equ DREQ_PWM_WRAP7,        39
    .equ DREQ_I2C0_TX,          40
    .equ DREQ_I2C0_RX,          41
    .equ DREQ_I2C1_TX,          42
    .equ DREQ_I2C1_RX,          43
    .equ DREQ_ADC,              44
    .equ DREQ_XIP_STREAM,       45
    .equ DREQ_XIP_QMITX,        46
    .equ DREQ_XIP_QMIRX,        47
    .equ DREQ_HSTX,             48
    .equ DREQ_CORESIGHT,        49
    .equ DREQ_SHA256,           50
    @ 51-58 reserved
    .equ DREQ_TIMER0,           59
    .equ DREQ_TIMER1,           60
    .equ DREQ_TIMER2,           61
    .equ DREQ_TIMER3,           62
    .equ DREQ_PERMANENT,        63        @ unpaced; runs as fast as bus allows

@ ----- SNIFF_CTRL fields (datasheet §12.6.2.5) -------------------------------
@   [0]    EN
@   [4:1]  DMACH    (channel index whose data stream feeds the sniffer)
@   [8:5]  CALC     (mode; see SNIFF_CRC32 / SNIFF_SUM below)
@   [9]    BSWAP
@   [10]   OUT_REV
@   [11]   OUT_INV
    .equ DMA_SNIFF_CTRL_EN_LSB,       0
    .equ DMA_SNIFF_CTRL_DMACH_LSB,    1
    .equ DMA_SNIFF_CTRL_CALC_LSB,     5
    .equ DMA_SNIFF_CTRL_BSWAP_LSB,    9
    .equ DMA_SNIFF_CTRL_OUT_REV_LSB,  10
    .equ DMA_SNIFF_CTRL_OUT_INV_LSB,  11

    @ CALC encodings (bits [8:5])
    .equ DMA_SNIFF_CRC32,             0       @ CRC-32 (reverse poly 0xEDB88320)
    .equ DMA_SNIFF_CRC32_REV,         1       @ CRC-32 bit-reversed input
    .equ DMA_SNIFF_CRC16,             2       @ CRC-16-CCITT
    .equ DMA_SNIFF_CRC16_REV,         3
    .equ DMA_SNIFF_EVEN,              14      @ XOR reduction (parity)
    .equ DMA_SNIFF_SUM,               15      @ 32-bit sum

@ ----- RESETS bit position for the DMA block ---------------------------------
@   Datasheet §7.5: bit 2 = dma.
    .equ RESETS_dma,                  2

@ ----- Convenience: pre-built CTRL words for the most common cases ----------
@   These default to CHAIN_TO = 0 (channel 0).  If you target a different
@   channel, OR in (chan_index << DMA_CTRL_CHAIN_TO_LSB) to point CHAIN_TO at
@   that channel - chaining a channel to itself is the standard "no chain"
@   convention on RP2350 (datasheet §12.6.2.4).
    .equ DMA_CTRL_MEM2MEM_WORD, (DMA_CTRL_EN | DMA_DATA_SIZE_WORD | DMA_CTRL_INCR_READ | DMA_CTRL_INCR_WRITE | (DREQ_PERMANENT << DMA_CTRL_TREQ_SEL_LSB))

    .equ DMA_CTRL_MEM2MEM_BYTE, (DMA_CTRL_EN | DMA_DATA_SIZE_BYTE | DMA_CTRL_INCR_READ | DMA_CTRL_INCR_WRITE | (DREQ_PERMANENT << DMA_CTRL_TREQ_SEL_LSB))
