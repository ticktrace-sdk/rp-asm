# SPI (PL022) controllers

This document covers the RP2350 SPI driver in `src/spi.S` and the three
end-to-end demos in `examples/spi_*.S`.

Datasheet refs:
* RP2350 datasheet rev 0.3 (Aug 2024) section 12.3.
* ARM PrimeCell SSP TRM (DDI 0194H) - canonical PL022 register map.

## Block at a glance

```
   +-----------------------------------------------------+
   |  SPI0 @ 0x40080000  (PL022 PrimeCell)               |
   |                                                     |
   |  +----+   +----+    +-----------+    +-----------+  |
   |  | TX |-->| TX |--> | TX shift  | -> MOSI / MISO  |
   |  | DR | 8 | FIFO    | register  | <- (slave mode) |
   |  +----+   +----+    +-----------+                  |
   |                          ^                         |
   |  +----+   +----+         |                         |
   |  | RX |<--| RX |<--------+ RX shift register       |
   |  | DR | 8 | FIFO                                   |
   |  +----+   +----+                                   |
   |                                                    |
   |  +----+ +----+ +----+ +----+ +----+ +----+ +----+  |
   |  |CR0 | |CR1 | |SR  | |CPSR| |IMSC| |ICR | |DMA |  |
   |  |    | |LBM/| |TFE/| | even| ROR/| | ROR| |TX/ |  |
   |  |DSS,| |SSE/| |TNF/| | divs| RT/ | | RT | | RX |  |
   |  |FRF,| |MS/ | |RNE/| | 2.. | RX/ | |    | |    |  |
   |  |SPO,| |SOD | |RFF/| |254 | TX  | |    | |    |  |
   |  |SPH,| |    | |BSY |  |   |    | |    | |    |  |
   |  |SCR | |    | |    | |    |    | |    | |    |  |
   |  +----+ +----+ +----+ +----+ +----+ +----+ +----+  |
   +-----------------------------------------------------+

   SPI1 @ 0x40088000 - identical layout, +0x8000 stride.
```

## Register map (relative to SPIn_BASE)

```
  +0x00  SSPCR0    DSS[3:0] FRF[5:4] SPO[6] SPH[7] SCR[15:8]
  +0x04  SSPCR1    LBM[0] SSE[1] MS[2] SOD[3]
  +0x08  SSPDR     16-bit data port (write -> TX FIFO; read -> RX FIFO)
  +0x0C  SSPSR     TFE[0] TNF[1] RNE[2] RFF[3] BSY[4]
  +0x10  SSPCPSR   CPSDVSR[7:0]  (even number, 2..254)
  +0x14  SSPIMSC   RORIM[0] RTIM[1] RXIM[2] TXIM[3]
  +0x18  SSPRIS    raw IRQ status
  +0x1C  SSPMIS    masked IRQ status (= RIS & IMSC)
  +0x20  SSPICR    W1C: bits 0/1 only (RORIC/RTIC)
  +0x24  SSPDMACR  RXDMAE[0] TXDMAE[1]
```

The standard atomic alias windows apply: `+0x1000` XOR, `+0x2000` SET,
`+0x3000` CLR.  The driver uses RMW for CR1 mutations rather than the
SET/CLR aliases because the SSE-on-CR0-stable invariant requires a
specific sequence.

## CPOL / CPHA matrix

| CPOL (SPO) | CPHA (SPH) | Sampled | Idle SCK | Notes                       |
|:----------:|:----------:|:-------:|:--------:|-----------------------------|
| 0          | 0          | rising  | low      | "Mode 0" - default          |
| 0          | 1          | falling | low      | "Mode 1"                    |
| 1          | 0          | falling | high     | "Mode 2"                    |
| 1          | 1          | rising  | high     | "Mode 3"                    |

Frame format (SSPCR0 bits [5:4]) selects the protocol on top of CPOL/CPHA:

| FRF | Protocol               | DSS supported   |
|-----|------------------------|-----------------|
| 0   | Motorola SPI           | 4..16 bits      |
| 1   | TI synchronous SSF     | 4..16 bits      |
| 2   | National Microwire     | 8 bits only     |

## Baud math

```
  effective_clock = clk_peri / (CPSDVSR * (1 + SCR))
```

with `clk_peri = 150 MHz` post-M2.  CPSDVSR is even, 2..254.  SCR is
0..255.  `spi_set_baudrate` walks CPSDVSR upward, computing the smallest
prescale that satisfies `(prescale + 2) * 256 * baud > clk_peri`, then
solves `SCR = round(clk_peri / (prescale * baud)) - 1`.  The 64-bit
UMULL guard avoids 32-bit overflow at very high baud (>16 MHz).

Achieved baud table on a 150 MHz `clk_peri`:

| Requested  | CPSDVSR | SCR | Achieved      | Error    |
|------------|---------|-----|---------------|----------|
| 1 MHz      | 2       | 74  | 1 000 000 Hz  | 0%       |
| 4 MHz      | 2       | 18  | 3 947 368 Hz  | -1.32%   |
| 25 MHz     | 2       | 2   | 25 000 000 Hz | 0%       |
| 75 MHz max | 2       | 0   | 75 000 000 Hz | 0%       |

SPI master Fmax on PL022 is `clk_peri / 2`; slave Fmax is `clk_peri / 12`.

## SSPFSSOUT vs SIO CS

PL022's `FSSOUT` line drops low for **exactly one frame** before rising
again.  That's incompatible with most SPI peripherals which expect CS to
stay low across an entire multi-byte transaction.

Our policy:
* `spi_set_pins(idx, sck, mosi, miso, cs)` configures **sck/mosi/miso
  via FUNCSEL=GPIO_FUNC_SPI** and treats **cs as a regular SIO
  output** that the application drives.
* `spi_cs_low(cs_pin)` / `spi_cs_high(cs_pin)` thinly wrap `gpio_put`
  for ergonomic call-site bracketing.
* Real CS bracketing - drive low, transfer, drive high - is the
  application's responsibility.

If your slave _does_ want per-frame FSS pulses (rare), pass `cs = -1` to
`spi_set_pins` to skip CS init and `gpio_set_function(cs_pin,
GPIO_FUNC_SPI)` it yourself.

## Driver API quick reference

| Symbol                                                     | Purpose                              |
|------------------------------------------------------------|--------------------------------------|
| `spi_init(idx, baud_hz)`                                   | Reset clear + 8-bit Motorola defaults + baud + SSE on |
| `spi_deinit(idx)`                                          | SSE off + reset assert               |
| `spi_set_baudrate(idx, baud_hz) -> r0`                     | Reprogram CPSDVSR + SCR; returns achieved baud |
| `spi_set_format(idx, bits, cpol, cpha, frf)`               | Rebuild CR0 keeping SCR              |
| `spi_set_slave(idx, on)`                                   | CR1.MS bit                           |
| `spi_set_loopback(idx, on)`                                | CR1.LBM bit                          |
| `spi_set_pins(idx, sck, mosi, miso, cs)`                   | gpio FUNCSEL on sck/mosi/miso; SIO out on cs |
| `spi_write_blocking(idx, src, len) -> r0`                  | Push len bytes; discard RX           |
| `spi_read_blocking(idx, repeated_tx, dst, len) -> r0`      | Clock dummy bytes; collect RX        |
| `spi_write_read_blocking(idx, src, dst, len) -> r0`        | Full duplex                          |
| `spi_is_writable(idx) -> r0`                               | TNF                                  |
| `spi_is_readable(idx) -> r0`                               | RNE                                  |
| `spi_is_busy(idx) -> r0`                                   | BSY                                  |
| `spi_set_irqs_enabled(idx, mask)`                          | SSPIMSC                              |
| `spi_clear_irq(idx, mask)`                                 | SSPICR (W1C; bits 0/1 only)          |
| `spi_set_dma_enabled(idx, tx_on, rx_on)`                   | SSPDMACR                             |
| `spi_cs_low(cs_pin)` / `spi_cs_high(cs_pin)`               | gpio_put wrappers                    |

### Cycle budgets (Cortex-M33 @ 150 MHz, no wait states)

| Symbol                            | Cycles                                |
|-----------------------------------|---------------------------------------|
| `spi_is_writable / readable / busy` | 4 (base + ldr SSPSR + lsr + and)    |
| `spi_write_blocking` inner step   | ~6 per byte once TNF asserts          |
| `spi_set_baudrate`                | ~30 (one UDIV + couple of comparisons)|
| `spi_init`                        | ~40 + reset settle                    |

## DMA chained-channel pattern

Two channels concurrently driving an SPI burst:

```
  ch0 (TX): READ_ADDR=src,    WRITE_ADDR=SSPDR (fixed),
            INCR_READ, paced by DREQ_SPI<n>_TX, count = N
  ch1 (RX): READ_ADDR=SSPDR (fixed), WRITE_ADDR=dst,
            INCR_WRITE, paced by DREQ_SPI<n>_RX, count = N
```

Wire it up as in `examples/spi_dma_demo.S`:

```c
spi_init(0, 1_000_000);
spi_set_loopback(0, 1);          // for self-test; remove for real link
spi_set_dma_enabled(0, /*tx*/1, /*rx*/1);

dma_init();
// Configure RX channel FIRST so it's armed before TX clocks start.
dma_channel_configure(/*ch=1*/, ctrl_rx, SPI0_BASE+SSPDR, dst, N, /*trig*/1);
// Then TX - this kicks the actual data movement.
dma_channel_configure(/*ch=0*/, ctrl_tx, src, SPI0_BASE+SSPDR, N, /*trig*/1);
```

DREQ codes (cross-checked against `include/dma.inc` TREQ table):

| Source     | Code |
|------------|------|
| SPI0 TX    | 24   |
| SPI0 RX    | 25   |
| SPI1 TX    | 26   |
| SPI1 RX    | 27   |

## Examples

| File                                              | What it does                          |
|---------------------------------------------------|---------------------------------------|
| `examples/spi_loopback_demo.S`                    | SPI0 internal LBM, 256-byte ramp self-test |
| `examples/spi_dma_demo.S`                         | SPI0 LBM + 2-channel DMA, 1 KiB pipe  |
| `examples/spi_master_slave_loopback_demo.S`       | SPI0 master <-> SPI1 slave with jumpers |

The loopback demos run at the bootrom-default 12 MHz `clk_peri` to keep
the UF2s small; real silicon at 150 MHz `clk_peri` would clock 12.5x
faster but the register write trace is identical.

## TODO (deffered)

- **No PLL bring-up in the demos.**  At 12 MHz `clk_peri`, the achieved
  baud at "1 MHz" is 12 MHz / (2 * 75) = 80 kHz.  This is fine for
  loopback and for proving the register sequence; real-link work needs
  the clocks demo's PLL bring-up first.
- **No FIFO threshold IRQs in the demos.**  RXIM/TXIM are exposed in
  `spi_set_irqs_enabled` but no example wires `NVIC` to handle them.
- **Slave mode CS is a single byte.**  PL022 in slave mode treats each
  rising FSS edge as end-of-frame and re-arms.  The master/slave demo
  sidesteps this by pre-loading the slave TX FIFO before the master
  starts clocking.

