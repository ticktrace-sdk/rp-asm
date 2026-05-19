# I2C (M4-F)

Two-wire serial bus controller.  RP2350 has **two instances** of the
Synopsys DesignWare DW_apb_i2c (same IP block as the RP2040).  Both can
operate as master or slave at Standard (100 kHz), Fast (400 kHz) or
Fast+ (1 MHz) speeds with 7- or 10-bit addressing.  Datasheet ref:
RP2350 sec 12.4 + the upstream Synopsys DW_apb_i2c databook.

The driver lives in `src/i2c.S`; register definitions in
`include/i2c.inc`; tests in `tests/unicorn/test_i2c.py`,
`tests/unicorn/mocks_i2c.py`, and the integration `.resc` at
`tests/renode/i2c.resc`.

## Bases and IRQ wiring

| Inst   | Base       | RESETS bit | NVIC IRQ | DREQ TX | DREQ RX |
|--------|-----------|-----------|----------|---------|---------|
| I2C0   | 0x40090000 | 4         | 35       | 40      | 41      |
| I2C1   | 0x40098000 | 5         | 36       | 42      | 43      |

(DREQ codes from `include/dma.inc` - shared with M3-C.)

## Register layout (subset; full list in include/i2c.inc)

| Off   | Name              | Notes                                          |
|-------|-------------------|------------------------------------------------|
| 0x00  | IC_CON            | mode + speed + enables; *R/O while enabled*    |
| 0x04  | IC_TAR            | target address (master mode)                   |
| 0x08  | IC_SAR            | own address (slave mode)                       |
| 0x10  | IC_DATA_CMD       | TX byte (write) / RX byte (read); see below    |
| 0x14  | IC_SS_SCL_HCNT    | SCL high count, Standard speed                 |
| 0x18  | IC_SS_SCL_LCNT    | SCL low count, Standard speed                  |
| 0x1C  | IC_FS_SCL_HCNT    | SCL high count, Fast / Fast+ speed             |
| 0x20  | IC_FS_SCL_LCNT    | SCL low count, Fast / Fast+ speed              |
| 0x2C  | IC_INTR_STAT      | post-mask IRQ status                           |
| 0x30  | IC_INTR_MASK      | per-source enables                             |
| 0x34  | IC_RAW_INTR_STAT  | raw IRQ status                                 |
| 0x40  | IC_CLR_INTR       | read to clear *all* sources at once            |
| 0x44.. 0x64 | IC_CLR_<x>  | read to clear *one* source at a time           |
| 0x6C  | IC_ENABLE         | bit 0 = master switch                          |
| 0x70  | IC_STATUS         | TFNF/TFE/RFNE/MST_ACTIVITY etc.                |
| 0x7C  | IC_SDA_HOLD       | SDA hold time in clk_peri ticks                |
| 0x80  | IC_TX_ABRT_SOURCE | non-zero -> last write/read NACKed             |
| 0x88  | IC_DMA_CR         | TX/RX DMA enable bits                          |
| 0xA0  | IC_FS_SPKLEN      | input-glitch filter (clk_peri ticks)           |

### IC_DATA_CMD bit layout

```
  [10] RESTART  - if set, issue RESTART before this byte
  [9]  STOP     - if set, issue STOP after this byte
  [8]  CMD      - 0 = master write, 1 = master read
  [7:0] DAT     - data byte (write) or received byte (read)
```

Master writes use bit 8 = 0 plus bit 9 = 1 on the last byte.  Master reads
push N words with bit 8 = 1 each; bit 9 = 1 on the last command issues
the STOP.  RESTART (bit 10) is set on the first command of a new
direction within the same transaction.

## Initialisation sequence (gotcha: ENABLE-must-be-0)

Per the DW databook §3.2.1, **most config registers (IC_CON, SCL counts,
IC_SAR, IC_FS_SPKLEN, IC_SDA_HOLD, IC_RX_TL, IC_TX_TL, IC_DMA_CR) are
read-only while IC_ENABLE = 1.**  A second-pass write to IC_CON without
first dropping IC_ENABLE is silently ignored, which is a classic
day-one-of-driver-bring-up bug.

The driver enforces:

```
RESETS_RESET CLR (1 << (4 + idx))      ; release from reset
spin on RESETS_RESET_DONE bit           ; wait for hardware ack
IC_ENABLE = 0                           ; unlock config
IC_CON = MASTER_MODE | SPEED_FS | RESTART_EN | SLAVE_DISABLE | TX_EMPTY_CTRL
IC_FS_SPKLEN = 2                        ; ~13 ns glitch filter at 150 MHz
IC_SS/FS_SCL_HCNT = ...                 ; speed-dependent
IC_SS/FS_SCL_LCNT = ...
IC_SDA_HOLD       = 10 (or 4 at 1 MHz)
IC_TX_TL = 0; IC_RX_TL = 0; IC_DMA_CR = 0; IC_INTR_MASK = 0
IC_ENABLE = 1                           ; commit
```

`i2c_set_baudrate` (called from `i2c_init` and re-callable later) wraps
the disable -> program -> re-enable dance.

## SCL HCNT / LCNT math

DesignWare wants HCNT / LCNT in units of `clk_peri` ticks.  The
inter-byte SCL period is `(HCNT + LCNT)` ticks plus a fixed overhead
(~8 ticks per period from the IC_FS_SPKLEN-driven glitch filter and
some HW-internal pipeline cycles).

Per the I2C-bus spec §6.1, each speed has minimum bus-high / bus-low
times:

| Speed       | freq       | tHIGH min | tLOW min | period |
|-------------|-----------|----------|----------|--------|
| Standard    | 100 kHz    | 4000 ns   | 4700 ns   | 10 us   |
| Fast        | 400 kHz    | 600 ns    | 1300 ns   | 2.5 us  |
| Fast+       | 1 MHz      | 260 ns    | 500 ns    | 1 us    |

At `clk_peri = 150 MHz` (RP2350 post-M2 default), one tick = 6.667 ns.
The driver computes:

```
period_ticks = clk_peri / freq                         ; e.g. 1500 @ 100 kHz
HCNT = period_ticks * 4 / 10 - 8   (clamped >= 8)      ; 40% high
LCNT = period_ticks * 6 / 10 - 1   (clamped >= 8)      ; 60% low
```

The 40/60 split follows the typical DesignWare reference; the -8 / -1
offsets compensate for the controller's own pre/post-amble overhead.

| freq    | period | HCNT | LCNT | HCNT+LCNT | Actual SCL |
|---------|-------|-----|-----|-----------|-----------|
| 100 kHz | 1500   | 592  | 899  | 1491       | 100.6 kHz   |
| 400 kHz |  375   | 142  | 224  |  366       | 409.8 kHz   |
| 1   MHz |  150   |  52  |  89  |  141       | 1064 kHz    |

These satisfy the spec minima for tHIGH and tLOW at every speed.

`IC_SDA_HOLD` is set to **10** at SS/FS (~67 ns hold) and **4** at 1 MHz
(~27 ns hold) so tHD;DAT stays under the 70 ns Fast+ ceiling.

## Which SCL register pair to use

The IC_CON.SPEED bits decide which HCNT/LCNT register pair is consulted
on each transfer.  The driver matches:

| baudrate   | IC_CON.SPEED | HCNT/LCNT pair        |
|------------|-------------|-----------------------|
| <= 100 kHz | 1 (SS)       | IC_SS_SCL_*           |
| > 100 kHz  | 2 (FS)       | IC_FS_SCL_*           |

The "FS" pair handles Fast (400 kHz) and Fast+ (1 MHz) - the controller
uses the FS pair for both, with the only difference being the hold time
and SCL count values you program.

## RESTART vs STOP semantics

- `i2c_write_blocking(idx, addr, src, len, nostop=0)` issues the address
  byte, all `len` data bytes, and a STOP after the last one.  The bus
  is released; any other master may take over.
- `i2c_write_blocking(idx, addr, src, len, nostop=1)` does **not** issue
  STOP - the master keeps the bus and the next call (typically a read)
  must include a RESTART, which the controller does automatically when
  IC_CON.RESTART_EN = 1 and the new transaction's first IC_DATA_CMD
  carries the address (effectively, when IC_TAR is rewritten to the
  same address with IC_ENABLE briefly toggled).  This is the canonical
  "set EEPROM read-pointer + read N bytes" pattern - see
  `examples/i2c_eeprom_demo.S`.
- `i2c_read_blocking(idx, addr, dst, len, nostop=0)` issues `len` read
  commands; the last one carries STOP.  With `nostop=1` the bus is
  held instead.

## DMA pacing

`IC_DMA_CR` enables TX/RX DMA requests:
- bit 0 (RDMAE) - request a DREQ_I2Cn_RX whenever IC_RXFLR > IC_DMA_RDLR
- bit 1 (TDMAE) - request a DREQ_I2Cn_TX whenever IC_TXFLR <= IC_DMA_TDLR

`i2c_set_dma_enabled(idx, tx, rx)` writes the bit pattern.  The DMA
channel still needs CTRL.TREQ_SEL = 40/41/42/43 (see include/dma.inc)
and READ_ADDR / WRITE_ADDR pointed at IC_DATA_CMD on the I2C side and
the user buffer on the other.

There's no integrated I2C+DMA example in M4-F (would require the M3-C
DMA driver and a non-trivial wiring); the API is plumbed through so
that future demos can stitch the two together.

## Cycle budgets (Cortex-M33 from SRAM, no APB wait states)

| Function                        | Cycles                                 |
|---------------------------------|----------------------------------------|
| `_i2c_base`                     | 3 (cmp + ldr)                          |
| `i2c_init`                      | ~30 + DesignWare settling time         |
| `i2c_set_baudrate`              | ~40 (UDIV pair + 4 stores)             |
| `i2c_set_pins`                  | ~40 (2 x gpio_set_function + 2 x pull_up) |
| `i2c_write_blocking` per byte   | ~12 + bus-paced wait                   |
| `i2c_clear_irq`                 | ~6 (single bus read, side-effect IS the read) |
| `i2c_get_status`                | 4                                      |

Bus speed dominates any non-trivial transfer: a 1-byte write at
100 kHz takes ~100 us regardless of how fast the CPU is.

## Public API

See the `i2c_*` symbols at the top of `src/i2c.S` for the full
declaration block; AAPCS calling convention throughout.

## Test coverage

- T1 (Unicorn host harness): `tests/unicorn/test_i2c.py` - 24 tests
  covering init, baudrate at 100k/400k/1M, write/read with and without
  STOP, IRQ mask programming, IC_CLR_INTR semantics, DMA enable bits,
  slave-mode entry, GPIO pin programming, and an end-to-end run through
  each of the three example ELFs.
- T3 (Renode integration): `tests/renode/i2c.resc` loads
  `build/i2c_eeprom_demo.elf`, runs 500 ms simulated, asserts that the
  UART captured the EEPROM write banner and the four-byte read-back
  pattern (`a5 b6 c7 d8`) from the I2C peripheral stub at addr 0x50.
