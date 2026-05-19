# PIO (M5-I)

RP2350 has **3 PIO blocks** (PIO0/PIO1/PIO2), up from 2 on RP2040. Each is
4 state machines × 32 instructions of program memory + per-SM 4-deep TX/RX
FIFOs. This page covers the controller-side driver. The PIO assembly
language itself (the 16-bit instruction encoding) gets a `pioasm` Python
tool in a later milestone.

Driver: `src/pio.S`. Defs: `include/pio.inc`. Bases: `0x50200000` /
`0x50300000` / `0x50400000`. RESETS bits: `11`, `12`, `13`.

> **Status:** PIO controller driver + a hand-encoded blink example +
> 10 T1 unit tests are shipped. The Python `pioasm` tool is deferred:
> users currently encode programs by hand (it's only 16 bits per
> instruction; see "Hand encoding" below).

## API

```
pio_init(r0=idx)                                deassert RESETS
pio_add_program(idx, prog, len, origin) -> r0   copy words into INSTR_MEM
pio_sm_set_clkdiv(idx, sm, int, frac)           CLKDIV = (int<<16) | (frac<<8)
pio_sm_set_wrap(idx, sm, bottom, top)           EXECCTRL WRAP fields
pio_sm_set_out_pins(idx, sm, base, count)       PINCTRL OUT_BASE/COUNT
pio_sm_set_set_pins(idx, sm, base, count)       PINCTRL SET_BASE/COUNT
pio_sm_set_enabled(idx, sm, on)                 CTRL.SM_ENABLE bit via SET/CLR
pio_sm_put(idx, sm, value)                      spin FSTAT.TX_FULL; store TXFn
pio_sm_get(idx, sm) -> r0                       spin FSTAT.RX_EMPTY; load RXFn
pio_sm_exec(idx, sm, instr)                     write SM_INSTR; runs immediately
pio_gpio_init(idx, pin)                         gpio_set_function(pin, 6+idx)
```

`idx` is `{0, 1, 2}`; `sm` is `{0, 1, 2, 3}`.

## Hand encoding the PIO program

Until `pioasm` lands, programs are written as `.word` arrays of pre-encoded
16-bit instructions. The 16-bit format:

```
  15 14 13 | 12 11 10  9  8 |  7  6  5 |  4  3  2  1  0
  --------- | --------------- | --------- | -----------------
   opcode   |  delay/sideset  |  dst/cond |  data / addr
```

Opcodes:

| `op` | mnemonic | dst / cond / extras            |
| ---: | -------- | ------------------------------- |
| 000  | JMP      | `cond` in [7:5], `addr` in [4:0] |
| 001  | WAIT     | `pol|src` in [7:5], `index` in [4:0] |
| 010  | IN       | `src` in [7:5], `bit_count` in [4:0] (0=32) |
| 011  | OUT      | `dst` in [7:5], `bit_count` in [4:0] |
| 100  | PUSH/PULL| `IfFull/IfEmpty` + `Block` in [7:5] |
| 101  | MOV      | `dst|op|src` in [7:0] |
| 110  | IRQ      | `Clear|WaitFlag|index` |
| 111  | SET      | `dst` in [7:5], `data` in [4:0] |

`SET dst` values: 0=pins, 1=X, 2=Y, 4=pindirs.

### Worked example: blink

```pio
.program blink
    set pins, 1 [31]
    set pins, 0 [31]
.wrap                       ; wrap_target = 0, wrap = 1
```

Encoded:

```
op=111 (SET) | delay=11111 | dst=000 (pins) | data=00001  -> 0xFF01
op=111 (SET) | delay=11111 | dst=000 (pins) | data=00000  -> 0xFF00
```

That's the entire `pio_blink_program` in `examples/pio_blink_demo.S`:

```asm
pio_blink_program:
    .word 0xFF01            @ SET PINS, 1 [31]
    .word 0xFF00            @ SET PINS, 0 [31]
```

(We store each 16-bit instruction in a 32-bit `.word` for easier
loading via `pio_add_program`; the upper 16 bits are ignored by the SM.)

## Quick start: blink a pin from PIO

```asm
    bl      pio_init                    @ r0=0 -> PIO0

    movs    r0, #0                      @ idx
    movs    r1, #25                     @ pin
    bl      pio_gpio_init               @ route GP25 to PIO0

    movs    r0, #0
    ldr     r1, =my_program
    movs    r2, #my_program_len
    movs    r3, #0                      @ origin
    bl      pio_add_program

    movs    r0, #0
    movs    r1, #0                      @ sm
    movw    r2, #0xFFFF                 @ clkdiv int (max slowdown)
    movs    r3, #0                      @ clkdiv frac
    bl      pio_sm_set_clkdiv

    movs    r0, #0
    movs    r1, #0
    movs    r2, #25                     @ SET base = LED_PIN
    movs    r3, #1                      @ SET count = 1
    bl      pio_sm_set_set_pins

    movs    r0, #0
    movs    r1, #0
    movs    r2, #0                      @ wrap bottom
    movs    r3, #1                      @ wrap top
    bl      pio_sm_set_wrap

    movs    r0, #0
    movs    r1, #0
    movs    r2, #1
    bl      pio_sm_set_enabled
```

After this, SM0 runs your loaded program forever; the CPU can `wfi`.

## Per-SM register stride

The 4 state machines per PIO occupy `[0xC8 .. 0x12F]`, stride `0x18`:

| Offset | Reg          |
| -----: | ------------ |
| +0x00  | CLKDIV       |
| +0x04  | EXECCTRL     |
| +0x08  | SHIFTCTRL    |
| +0x0C  | ADDR (RO)    |
| +0x10  | INSTR        |
| +0x14  | PINCTRL      |

`PINCTRL` packs all the pin assignments for the SM:

| Bits   | Field          | Width |
| -----: | -------------- | ----: |
| 4:0    | OUT_BASE       | 5     |
| 9:5    | SET_BASE       | 5     |
| 14:10  | SIDESET_BASE   | 5     |
| 19:15  | IN_BASE        | 5     |
| 25:20  | OUT_COUNT      | 6     |
| 28:26  | SET_COUNT      | 3     |
| 31:29  | SIDESET_COUNT  | 3     |

## DMA pacing

Each SM exposes two DREQs: `PIOn_TXm` and `PIOn_RXm` (n ∈ {0,1,2}, m ∈
{0..3}). The exact codes are in `include/dma.inc`. A typical pattern:

- Configure a DMA channel with `TREQ_SEL = PIO0_TX0`, `INCR_READ`, no
  `INCR_WRITE` (every byte hits the same `TXF0` register).
- DMA streams data to the SM; the SM pulls from the TX FIFO whenever
  `OUT` or `PULL` executes.

## Build artefacts

- `build/pio_blink_demo.uf2`: PIO0 SM0 drives GP25 at ~36 Hz square
  wave. LED appears solid-dim to the eye; verify with a logic analyser.

## T1 tests

`tests/unicorn/test_pio.py` (10 cases). The fixture maps the
`0x50200000..0x50404000` window plus its atomic aliases via a `_map_pio`
helper (PIO sits outside the harness's APB pre-mapping at `0x40000000`).

- `pio_init` RESETS bit math for all 3 blocks (11/12/13).
- `pio_add_program` copy semantics + non-zero `origin`.
- `pio_sm_set_clkdiv` field packing.
- `pio_sm_set_enabled` picks SET vs CLR alias correctly.
- `pio_sm_put` spins on TX_FULL, then stores once.
- `pio_sm_exec` writes the instruction word to `SM_INSTR`.
- `pio_sm_set_set_pins` / `pio_sm_set_wrap` RMW preserves unrelated
  bitfields.
- `pio_gpio_init` dispatches `gpio_set_function(pin, 6+pio_idx)`.

## Coming later (deferred)

- `tools/pioasm.py`: Python assembler producing `.S`-emittable program blobs.
- DMA-fed `ws2812.pio` example with a side-set program.
- IRQ-based RX FIFO drain via `pio_sm_set_irq_handler`.
