# M3-A: GPIO / PADS

Full RP2350 GPIO subsystem coverage: 48 user GPIOs in IO_BANK0 + 6 QSPI
pins in IO_QSPI, all atomic-aliased and per-pad configurable. This is the
"complete" GPIO driver; it supersedes the v0.1 single-pin LED helpers,
which remain as thin back-compat shims (`gpio_led_init`,
`gpio_led_toggle`).

## Files

| Path                                | Role                                                |
| ----------------------------------- | --------------------------------------------------- |
| `include/gpio.inc`                  | IO_BANK0 + IO_QSPI register/bit defs                |
| `include/pads.inc`                  | PADS_BANK0 + PADS_QSPI register/bit defs            |
| `src/gpio.S`                        | the driver (all public functions below)             |
| `examples/gpio_demo.S`              | 3-LED bar pattern on GP22/23/24                     |
| `examples/gpio_irq_demo.S`          | GP0 falling edge → toggle LED                       |
| `examples/gpio_test_fixture.S`      | unit-test fixture: references every public symbol   |
| `tests/unicorn/test_gpio.py`        | T1 trace tests for every public function            |
| `tests/unicorn/mocks_gpio.py`       | helpers + AAPCS call wrapper                        |
| `tests/renode/gpio.resc`            | T3 integration test (gpio_demo.elf)                 |
| `tests/renode/gpio_peripheral.py`   | RP2350 IO_BANK0/PADS/SIO write decoder              |

## Public API

All functions follow the AAPCS calling convention; r0..r3 are clobbered
unless noted. `pin` is 0..47 for IO_BANK0 functions, 0..5 for the
`gpio_qspi_*` mirror.

### Configuration

```
gpio_init(pin)                  pad: ATOMIC_CLR ISO|OD; mux: SIO;
                                SIO: OUT=0, OE=0      (4 stores)
gpio_deinit(pin)                mux: NULL; pad: ATOMIC_SET ISO|OD
gpio_set_function(pin, func)    IO_BANK0 CTRL FUNCSEL = func
gpio_set_dir(pin, out_bool)     SIO_GPIO_OE_SET / OE_CLR
gpio_set_input_enabled(pin, en) PADS IE
gpio_set_drive_strength(pin, d) PADS DRIVE: 0=2mA 1=4mA 2=8mA 3=12mA
gpio_set_slew_fast(pin, fast)   PADS SLEWFAST
gpio_set_schmitt(pin, on)       PADS SCHMITT
gpio_pull_up(pin)               PADS PUE=1, PDE=0  (atomic SET+CLR)
gpio_pull_down(pin)             PADS PUE=0, PDE=1  (atomic CLR+SET)
gpio_disable_pulls(pin)         PADS PUE=0, PDE=0  (single CLR)
```

### Drive / sense

```
gpio_put(pin, value)            single store to OUT_SET / OUT_CLR
gpio_toggle(pin)                single store to OUT_XOR
gpio_get(pin) -> r0             read OE, return bit n as 0/1
```

### Interrupts (PROC0 line)

```
gpio_set_irq_enabled(pin, events_mask, enable)
                                events_mask in {LEVEL_LOW=1, LEVEL_HIGH=2,
                                                EDGE_LOW=4,  EDGE_HIGH=8}
                                writes via PROC0_INTE [pin/8] atomic SET/CLR
gpio_acknowledge_irq(pin, events_mask)
                                W1C on INTR[pin/8] for the matching nibble
```

### IO_QSPI mirror (6 pins)

```
gpio_qspi_set_function(pin, func)
gpio_qspi_set_irq_enabled(pin, events_mask, enable)
gpio_qspi_acknowledge_irq(pin, events_mask)
```

### v0.1 shims

```
gpio_led_init      preserved verbatim, still callable
gpio_led_toggle    preserved verbatim, still callable
```

## Pin table

RP2350 has 48 user GPIOs (GP0..GP47) plus 6 QSPI pins. The function-mux
maps each GPIO onto one of these per-pin alternate functions
(datasheet rev 0.3 sec 9.1.1, table 597):

| FUNCSEL | Name      | Typical use                            |
| ------- | --------- | -------------------------------------- |
| 0       | XIP       | flash QSPI                             |
| 1       | SPI       | SPI controller IO                      |
| 2       | UART      | PL011 UART TX/RX/CTS/RTS               |
| 3       | I2C       | I²C SDA/SCL                            |
| 4       | PWM       | PWM channel A/B                        |
| 5       | SIO       | software-driven via SIO single-cycle IO|
| 6       | PIO0      | PIO0 instruction stream                |
| 7       | PIO1      | PIO1                                   |
| 8       | PIO2      | PIO2 (RP2350 only)                     |
| 9       | GPCK      | clock-gen / HSTX                       |
| 10      | USB       | USB OVCUR / VBUS_DETECT / VBUS_EN      |
| 11      | UART_AUX  | UART secondary lines                   |
| 31      | NULL      | function disconnected (default)        |

## Pad register layout (PADS_BANK0 + PADS_QSPI)

Per-pad register at offset `4 + n*4`:

| Bit | Field    | Reset | Meaning                                |
| --- | -------- | ----- | -------------------------------------- |
| 0   | SLEWFAST | 0     | 1 = fast slew                          |
| 1   | SCHMITT  | 1     | 1 = Schmitt trigger on input           |
| 2   | PDE      | 0     | pull-down enable                       |
| 3   | PUE      | 0     | pull-up enable                         |
| 5:4 | DRIVE    | 1     | 00=2mA, 01=4mA, 10=8mA, 11=12mA        |
| 6   | IE       | 0     | input enable, must be 1 to read pin    |
| 7   | OD       | 1     | output disable                         |
| 8   | ISO      | 1     | pad isolation                          |

### ISO + OD erratum note

Per datasheet sec 9.3.1, every pad on RP2350 boots with **ISO=1 + OD=1**.
This is a deliberate ESD-/glitch-safety state on the new silicon; it
differs from RP2040, where ISO does not exist. Code that drives a pin
**must** clear those bits before the SIO output reaches the package, or
the pin will read floating-input regardless of OE. `gpio_init` does this
as its first store (PADS_BANK0 ATOMIC_CLR with value 0x180).

## IRQ programming model

The IO_BANK0 IRQ subsystem packs 4 event bits per pin into one nibble;
each 32-bit register holds 8 pins. For pin `n`:

```
register index = n / 8        (0..5)
nibble shift   = (n % 8) * 4
events_mask    = LEVEL_LOW | LEVEL_HIGH | EDGE_LOW | EDGE_HIGH (any subset)
```

Each "kind" lives in its own array of 6 registers:

| Array               | Offset | Semantics                              |
| ------------------- | ------ | -------------------------------------- |
| INTR0..5            | 0x230  | RAW status; W1C the EDGE bits          |
| PROC0_INTE0..5      | 0x248  | PROC0 enable mask                      |
| PROC0_INTF0..5      | 0x260  | PROC0 force                            |
| PROC0_INTS0..5      | 0x278  | PROC0 (raw & enable) | force           |
| PROC1_INTE/INTF/INTS| 0x290  | same shape, for the second M33         |
| DORMANT_WAKE_*      | 0x2D8  | wakes the chip out of DORMANT          |

`gpio_set_irq_enabled(pin, mask, en)` writes `(mask << ((pin%8)*4))` to
`PROC0_INTE0 + (pin/8)*4`, choosing between `ATOMIC_SET` (en≠0) and
`ATOMIC_CLR` (en=0). `gpio_acknowledge_irq(pin, mask)` writes the same
shifted value to `INTR0 + (pin/8)*4` on the plain alias; the W1C
hardware then clears just the EDGE bits in that nibble. LEVEL events are
not W1C; they self-clear when the line condition goes away.

To drive an actual NVIC line, the IO_BANK0 PROC0 IRQ output (`IO_IRQ_BANK0`,
NVIC vector 13) needs to be enabled separately. M3-A intentionally does
*not* program the NVIC (that's the SysTick/TIMER agent's slot); the
`gpio_irq_demo.S` example polls `INTS0` in firmware to demonstrate the
event nibble shifting end-to-end.

## Cycle counts

Measured on Cortex-M33 from SRAM, with the constant pool already loaded
(no I-cache miss). Numbers ignore branch-target alignment overhead.

| Function                  | Stores | Approx cycles | Notes                         |
| ------------------------- | ------ | ------------- | ----------------------------- |
| `gpio_put`                | 1      | 4             | mask + cmp + str              |
| `gpio_toggle`             | 1      | 4             | mask + cmp + str              |
| `gpio_get`                | 0      | 6             | ldr + lsrs + ands             |
| `gpio_set_function`       | 1      | 8             | shift + str                   |
| `gpio_set_dir`            | 1      | 9             | cmp + mask + str              |
| `gpio_init`               | 4      | ~25           | PAD CLR + mux + OUT_CLR + OE_CLR |
| `gpio_deinit`             | 2      | ~14           | mux NULL + PAD SET            |
| `gpio_pull_up`            | 2      | ~12           | atomic SET PUE + CLR PDE      |
| `gpio_pull_down`          | 2      | ~12           | atomic SET PDE + CLR PUE      |
| `gpio_disable_pulls`      | 1      | 8             | atomic CLR (PUE \| PDE)       |
| `gpio_set_drive_strength` | 2      | ~14           | CLR DRIVE + SET new value     |
| `gpio_set_irq_enabled`    | 1      | ~22           | shift + atomic SET/CLR        |
| `gpio_acknowledge_irq`    | 1      | ~16           | shift + W1C                   |

The hot path (`gpio_put` / `gpio_toggle` / `gpio_get`) is ≤ 6 cycles,
suitable for bit-bang protocols up to ~25 MHz at clk_sys=150 MHz.

## High-pin (≥32) handling

Pins 32..47 live in the SIO `_HI` register window, 0x40 bytes above the
low window:

| Low offset | High offset | Register   |
| ---------- | ----------- | ---------- |
| 0x010      | 0x050       | OUT        |
| 0x018      | 0x058       | OUT_SET    |
| 0x020      | 0x060       | OUT_CLR    |
| 0x028      | 0x068       | OUT_XOR    |
| 0x030      | 0x070       | OE         |
| 0x038      | 0x078       | OE_SET     |
| 0x040      | 0x080       | OE_CLR     |
| 0x048      | 0x088       | OE_XOR     |
| 0x004      | 0x008       | IN         |

The driver always uses `pin - 32` as the bit position in the HI window
(rather than `pin & 31`) to make the intent explicit. Cortex-M33 LSLS
takes the full byte of the shift register, so `1 << 33` would be 0
silicon-correct; the explicit subtract is what makes pin 33 land at
bit 1 in the HI register, as the datasheet specifies.

## Testing

T1 (Unicorn) tests in `tests/unicorn/test_gpio.py` lock the exact MMIO
write trace for every public function. T3 (Renode) loads
`build/gpio_demo.elf`, runs 100 ms of simulated time, and asserts at
least 8 SIO_GPIO_OUT_* events on the watched pins.

The v0.1 regression test (`tests/unicorn/test_v01_blinky.py`,
unchanged from M2) continues to pass; `gpio_led_init` and
`gpio_led_toggle` emit byte-identical write traces.
