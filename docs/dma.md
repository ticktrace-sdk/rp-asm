# M3-C - DMA controller

This document covers the RP2350 DMA controller driver in `src/dma.S` and
the three end-to-end demos in `examples/dma_*.S`.

Datasheet reference: RP2350 datasheet rev 0.3 (Aug 2024) section 12.6.

## Block at a glance

```
   +---------------------------------------------------------------+
   |  DMA controller @ 0x50000000                                  |
   |                                                               |
   |  +--- 16 channels --------+   +--- 4 IRQ aggregators ------+  |
   |  | ch0  READ/WRITE/COUNT  |   | INTE0/INTF0/INTS0/INTR     |  |
   |  | ch1  + 4 alias sets    |   | INTE1/INTF1/INTS1          |  |
   |  | ...                    |   | INTE2/INTF2/INTS2          |  |
   |  | ch15                   |   | INTE3/INTF3/INTS3          |  |
   |  +------------------------+   +----------------------------+  |
   |                                                               |
   |  +--- 4 pacing TIMERs ---+    +--- 1 sniffer / CRC -------+   |
   |  | TIMER0..3 = X/Y div   |    | SNIFF_CTRL / SNIFF_DATA   |   |
   |  | -> TREQ 59..62        |    | CRC32 / CRC16 / SUM ...   |   |
   |  +-----------------------+    +---------------------------+   |
   +---------------------------------------------------------------+
                              |
                              v
              +--------------------------------+
              |  AHB-Lite bus master           |
              |  (talks to SRAM, XIP, periph)  |
              +--------------------------------+
```

## Per-channel layout (size 0x40, channel n at +n*0x40)

```
  +0x00  READ_ADDR
  +0x04  WRITE_ADDR
  +0x08  TRANS_COUNT
  +0x0C  CTRL_TRIG          <-- writing this LATCHES + STARTS the transfer
  +0x10  AL1_CTRL           <-- write CTRL without trigger
  +0x14  AL1_READ_ADDR
  +0x18  AL1_WRITE_ADDR
  +0x1C  AL1_TRANS_COUNT_TRIG  <-- writing this triggers
  +0x20  AL2_CTRL
  +0x24  AL2_TRANS_COUNT
  +0x28  AL2_READ_ADDR
  +0x2C  AL2_WRITE_ADDR_TRIG   <-- writing this triggers
  +0x30  AL3_CTRL
  +0x34  AL3_WRITE_ADDR
  +0x38  AL3_TRANS_COUNT
  +0x3C  AL3_READ_ADDR_TRIG    <-- writing this triggers
```

The four alias sets exist so you can pick which final write triggers
the transfer.  Pattern:

- "Configure-then-trigger": fill READ_ADDR / WRITE_ADDR / TRANS_COUNT
  via the canonical alias 0 offsets, then write CTRL_TRIG last.  This is
  what `dma_channel_configure(..., trigger=1)` does.
- "Re-arm with new dst": fill CTRL once, then later `str` the new
  WRITE_ADDR via AL2_WRITE_ADDR_TRIG (offset +0x2C) to launch each batch
  with a single store.  Useful for double-buffering.
- "Re-arm with new src": symmetric using AL3_READ_ADDR_TRIG (+0x3C).
- "Re-arm with new count": use AL1_TRANS_COUNT_TRIG (+0x1C).

The last two save (significantly) on critical-path latency vs. the
configure-then-trigger pattern.

## CTRL bitfield (CTRL / CTRL_TRIG / AL[1..3]_CTRL all share the layout)

| Bits  | Field         | Notes                                          |
|-------|---------------|------------------------------------------------|
| 0     | EN            | Enable channel                                 |
| 1     | HIGH_PRIORITY | Round-robin bias (vs other HIGH_PRIORITY chs)  |
| 3:2   | DATA_SIZE     | 0=byte, 1=halfword, 2=word                     |
| 4     | INCR_READ     | Auto-increment READ_ADDR after each beat       |
| 5     | INCR_READ_REV | Decrement instead of increment                 |
| 6     | INCR_WRITE    | Auto-increment WRITE_ADDR after each beat      |
| 7     | INCR_WRITE_REV| Decrement instead of increment                 |
| 11:8  | RING_SIZE     | Wrap addr at 1<<RING_SIZE bytes (0 = no wrap)  |
| 12    | RING_SEL      | 0 = wrap READ_ADDR, 1 = wrap WRITE_ADDR        |
| 16:13 | CHAIN_TO      | Channel index to chain to (= self -> no chain) |
| 22:17 | TREQ_SEL      | DREQ source (see table below)                  |
| 23    | IRQ_QUIET     | Suppress IRQ on completion                     |
| 24    | BSWAP         | Endian-swap each beat in the data path         |
| 25    | SNIFF_EN      | Feed this channel's data through the sniffer   |
| 26    | BUSY          | (RO) channel is currently transferring         |
| 29    | READ_ERROR    | (W1C) Sticky AHB read error                    |
| 30    | WRITE_ERROR   | (W1C) Sticky AHB write error                   |
| 31    | AHB_ERROR     | (RO) READ_ERROR | WRITE_ERROR                  |

## TREQ codes (CTRL[22:17])

| Code | Source        | Code | Source       |
|------|---------------|------|--------------|
| 0..3 | PIO0 TX 0..3  | 28   | UART0 TX     |
| 4..7 | PIO0 RX 0..3  | 29   | UART0 RX     |
| 8..11| PIO1 TX 0..3  | 30   | UART1 TX     |
|12..15| PIO1 RX 0..3  | 31   | UART1 RX     |
|16..19| PIO2 TX 0..3  |32..39| PWM_WRAP 0..7|
|20..23| PIO2 RX 0..3  | 40   | I2C0 TX      |
| 24   | SPI0 TX       | 41   | I2C0 RX      |
| 25   | SPI0 RX       | 42   | I2C1 TX      |
| 26   | SPI1 TX       | 43   | I2C1 RX      |
| 27   | SPI1 RX       | 44   | ADC          |
|45..47| XIP STREAM/QMI| 48   | HSTX         |
| 49   | CORESIGHT     | 50   | SHA256       |
|59..62| TIMER0..3     | 63   | PERMANENT    |

PERMANENT (63) means "no DREQ; just go as fast as the bus allows".  Use
it for memory-to-memory transfers.

## Driver API quick reference

| Symbol                                | Purpose                              |
|---------------------------------------|--------------------------------------|
| `dma_init`                            | Bring controller out of reset        |
| `dma_resets_enable`                   | Alias for `dma_init`                 |
| `dma_channel_set_read(ch, addr)`      | AL1_READ_ADDR (no trigger)           |
| `dma_channel_set_write(ch, addr)`     | AL1_WRITE_ADDR (no trigger)          |
| `dma_channel_set_trans_count(ch, n)`  | TRANS_COUNT (no trigger)             |
| `dma_channel_set_ctrl(ch, ctrl)`      | AL1_CTRL (no trigger)                |
| `dma_channel_configure(ch, ctrl, r, w, n, trig)` | 5 stores; trig => START   |
| `dma_channel_start(ch)`               | MULTI_CHAN_TRIGGER = 1<<ch           |
| `dma_channel_wait_for_finish(ch)`     | spin until CTRL.BUSY = 0             |
| `dma_channel_abort(ch)`               | CHAN_ABORT = 1<<ch; spin until clear |
| `dma_channel_irq_enable(ch, agg)`     | INTE[agg] |= 1<<ch via SET alias     |
| `dma_channel_acknowledge_irq(ch, agg)`| INTR W1C 1<<ch                       |
| `dma_sniff_enable(ch, mode)`          | SNIFF_CTRL = (mode<<5)|(ch<<1)|EN    |
| `dma_sniff_get_data() -> r0`          | Read SNIFF_DATA                      |

### Cycle budgets (cortex-m33 @ 150 MHz, no wait states)

| Symbol                            | Cycles                              |
|-----------------------------------|-------------------------------------|
| `dma_init`                        | ~10 + reset settle                  |
| `dma_channel_configure` (trig)    | ~14 (5 stores + frame + bx)         |
| `dma_channel_configure` (no-trig) | ~12                                 |
| `dma_channel_start`               | 4                                   |
| `dma_channel_wait_for_finish`     | 3 cycles per spin iteration         |
| `dma_channel_abort`               | 4 + 3 cycles per spin iteration     |
| `dma_sniff_enable`                | ~12                                 |

## Convenience CTRL templates

`include/dma.inc` exposes pre-built CTRL words for the common cases:

- `DMA_CTRL_MEM2MEM_WORD` - EN | DATA_SIZE_WORD | INCR_R | INCR_W | TREQ_PERMANENT
- `DMA_CTRL_MEM2MEM_BYTE` - same with byte-sized beats

CHAIN_TO defaults to 0 (= channel 0 = "no chain" when targeting ch0).
For other target channels, OR in `(ch << DMA_CTRL_CHAIN_TO_LSB)`.

## Chained transfers

CTRL.CHAIN_TO names a sibling channel that is **triggered automatically**
when this channel's TRANS_COUNT reaches zero.  Idiomatic uses:

- **Sentinel-then-payload**: chain a 1-beat ch0 (writes a "start"
  marker) to ch1 (the bulk transfer).
- **Double-buffering**: ch0 chains to ch1, ch1 chains back to ch0;
  flip the AL2_WRITE_ADDR_TRIG of each between every wrap.
- **Linked-list DMA**: have ch0 read its own register block from a
  table in memory by chaining to ch1 (1 beat) which writes the table
  pointer back into ch0's CTRL_TRIG via AL3_READ_ADDR_TRIG.

CHAIN_TO = self disables chaining (the most common case).

## Sniffer / CRC engine

The sniffer is a tap on a single channel's data path.  Enable it via:

```
dma_sniff_enable(ch, mode)
```

and set `CTRL.SNIFF_EN = 1` on the same channel.

| `mode` value           | Algorithm                          |
|------------------------|------------------------------------|
| `DMA_SNIFF_CRC32`      | CRC-32 (poly 0xEDB88320, init -1)  |
| `DMA_SNIFF_CRC32_REV`  | CRC-32 with bit-reversed input     |
| `DMA_SNIFF_CRC16`      | CRC-16-CCITT (init 0xFFFF)         |
| `DMA_SNIFF_CRC16_REV`  | CRC-16-CCITT bit-reversed input    |
| `DMA_SNIFF_EVEN`       | XOR-reduce (parity)                |
| `DMA_SNIFF_SUM`        | 32-bit running sum                 |

The sniffer accumulates across triggers - call `dma_sniff_enable()`
again before each new run to reset the accumulator (the helper writes
`SNIFF_DATA = 0` for you).

## Examples

| File                            | What it does                            |
|---------------------------------|-----------------------------------------|
| `examples/dma_memcpy_demo.S`    | 1 KiB mem-to-mem, prints DMA vs CPU cyc |
| `examples/dma_uart_demo.S`      | DREQ_UART0_TX-paced TX of a banner      |
| `examples/dma_sniff_demo.S`     | 256 B copy + CRC32 + UART hex print     |

All three avoid the full PLL/clocks bring-up and run at the bootrom
12 MHz default - keeps the UF2s small and isolates DMA behaviour from
clock-tree side effects.

## Caveats / what the M3-C model does NOT do

- TIMER0..3 pacing dividers: registers are defined but the demos don't
  exercise fractional pacing.
- AHB error injection / handling: the READ_ERROR / WRITE_ERROR W1C
  bits are exposed but no firmware path explicitly clears them.
- BSWAP, RING_SIZE / RING_SEL: bitfield positions are defined but no
  demo or test uses them.
- IRQ aggregator routing past INTE0..3 SET: NVIC enable is intentionally
  out of scope (M3-D NVIC milestone owns that).
- The Renode model (`tests/renode/dma_peripheral.py`) does the byte-level
  copy synchronously on trigger and never asserts the BUSY bit, so any
  test that depends on a non-zero BUSY observation must be a Unicorn
  test, not a Renode one.

## Datasheet vs implementation cross-check

All field positions and TREQ codes have been cross-checked against
RP2350 rev 0.3 (Aug 2024) section 12.6.  Discrepancies / open
questions:

- `DMA_INTR1` / `DMA_INTR2` / `DMA_INTR3` aliases at +0x410/+0x420/+0x430
  appear in some draft docs as separate "raw status" copies but the
  RP2350 datasheet rev 0.3 only describes a single `INTR` at +0x400 with
  W1C semantics.  M3-C exposes `DMA_INTR` only; sibling agents/tests that
  reach for `INTR1+` should be revisited if the datasheet changes.
- The TIMER0..3 register block at +0x420..+0x42C overlaps with the
  IRQ aggregator window in a way that's worth double-checking against
  silicon (the model in `tests/renode/dma_peripheral.py` treats them as
  distinct).
