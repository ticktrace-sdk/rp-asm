# PWM 

Pulse-width modulation peripheral.  RP2350 has **12 slices**, each with two
output channels (A and B), giving 24 PWM-capable outputs.  Datasheet
reference: RP2350 sec 12.5.

The driver lives in `src/pwm.S`; register definitions in
`include/pwm.inc`; tests in `tests/unicorn/test_pwm.py` and
`tests/renode/pwm.resc`.

## Slice layout

Each slice is a 16-bit free-running counter with an 8.4-bit fractional
clock divider, two compare values (CC.A in low half, CC.B in high half of
a 32-bit register), and a TOP wrap value.

```
    +0x00  CSR    EN | PH_CORRECT | A_INV | B_INV | DIVMODE[1:0] | PH_RET | PH_ADV
    +0x04  DIV    [11:4] integer  [3:0] fractional                (8.4 fp)
    +0x08  CTR    16-bit current count
    +0x0C  CC     [31:16] channel B level   [15:0] channel A level
    +0x10  TOP    16-bit wrap point
```

Stride 0x14, 12 slices, base 0x400a8000.

Global registers at `PWM_BASE + 0xF0+`:

| Off   | Name | Notes                                                  |
|-------|------|--------------------------------------------------------|
| 0xF0  | EN   | one bit per slice; atomic alternative to per-slice EN  |
| 0xF4  | INTR | wrap-IRQ pending; write 1 to clear                     |
| 0xF8  | INTE | wrap-IRQ enable (per slice)                            |
| 0xFC  | INTF | force-IRQ shadow                                       |
| 0x100 | INTS | post-mask status (RO)                                  |

## GPIO -> slice / channel mapping

Formula used in `include/pwm.inc` and `tests/unicorn/mocks_pwm.py`:

```
slice = ((pin >> 1) & 7) | ((pin >> 4) & 8)
chan  = pin & 1            (A = even pins, B = odd pins)
```

| GPIO | Slice | Channel | Notes                          |
|------|-------|---------|--------------------------------|
| GP0  | 0     | A       | UART0 TX in our build          |
| GP1  | 0     | B       | UART0 RX in our build          |
| GP2  | 1     | A       |                                |
| GP15 | 7     | B       | used by `pwm_fade_demo.S`      |
| GP16 | 0     | A       | wrap (low slice bits collide)  |
| GP24 | 4     | A       |                                |
| GP25 | 4     | B       | on-board LED on Pico 2         |
| GP47 | 7     | B       | top of GPIO range              |

> **Datasheet discrepancy.** The RP2350 SDK header `hardware/pwm.h` ships
> two slightly different macros across SDK versions; we pinned the form
> above because it matches both the GP15 and GP25 expectations the
> orchestrator stated.  Slices 8..11 are not reachable from any GPIO via
> this formula -- they're presumably for internal use.  Verify against the
> table in datasheet sec 12.5 if you intend to drive a pin not listed here.

To route a pad to its PWM slice/channel, call:

```
    movs    r0, #15             @ GP15
    bl      pwm_set_gpio_function
```

This clears `PADS_BANK0[15]` ISO+OD and writes `IO_BANK0[15].CTRL = 4`
(FUNCSEL = PWM).

## Frequency / duty math

Effective clock per slice:
```
    f_slice = clk_sys / (DIV.int + DIV.frac/16)
```
PWM frequency:
```
    f_pwm   = f_slice / (TOP + 1)         in free-running mode
            = f_slice / (2 * TOP)         in phase-correct mode
```
Duty cycle on channel X:
```
    duty    = CC.X / (TOP + 1)            in free-running mode
            = CC.X / TOP                  in phase-correct mode
```

Rule of thumb: keep `TOP >= 100` for ~1% duty resolution.  At
`clk_sys = 150 MHz`:

| Use case        | DIV.int | TOP    | f_pwm    | duty res. |
|-----------------|---------|--------|----------|-----------|
| LED fade        | 6       | 100    | 250 kHz  | 1%        |
| Servo (50 Hz)   | 150     | 19999  | 50 Hz    | 0.005%    |
| Audio (20 kHz)  | 1       | 7499   | 20 kHz   | 0.013%    |
| Buzzer (1 kHz)  | 3       | 49999  | 1 kHz    | 0.002%    |

The high-level `pwm_set_freq_hz(slice, freq, src_hz)` helper computes
DIV.int and TOP from the requested frequency:
1. `ticks = src_hz / freq`
2. If `ticks <= 65535`: `DIV.int = 1`, `TOP = ticks - 1`.
3. Else: `DIV.int = ceil(ticks / 65536)`, `TOP = ticks/DIV.int - 1`.

`DIV.frac` is left at 0; callers wanting sub-Hz precision program DIV
directly via `pwm_set_clkdiv(slice, int, frac)`.

## Phase-correct vs free-running

`CSR.PH_CORRECT = 0` (default) is the simple "saw-tooth" mode: the counter
runs 0 -> TOP -> wrap -> 0.  The output is high while `CTR < CC.X`.

`CSR.PH_CORRECT = 1` is "triangle" mode: 0 -> TOP -> 0 -> ...  This halves
the effective frequency but produces output edges that are symmetric about
TOP -- useful for motor drive (no DC offset between consecutive cycles
when both channels are used) and class-D audio (less phase distortion).

## Cycle budgets

Driver functions (Cortex-M33 @ 150 MHz, no wait states):

| Function                      | Stores | Cycles  | Notes                  |
|-------------------------------|--------|---------|------------------------|
| `pwm_set_chan_level`          | 1 STRH | ~9      | 16-bit half-store      |
| `pwm_set_both_levels`         | 1 STR  | ~9      | single 32-bit store    |
| `pwm_set_enabled`             | 1 STR  | ~7      | atomic SET/CLR alias   |
| `pwm_set_wrap`                | 1 STR  | ~7      |                        |
| `pwm_set_clkdiv_int`          | 1 STR  | ~8      |                        |
| `pwm_set_phase_correct`       | 1 STR  | ~10     | atomic SET/CLR         |
| `pwm_set_output_polarity`     | 2 STR  | ~14     | SET + CLR pair         |
| `pwm_irq_enable`              | 1 STR  | ~7      | atomic SET/CLR         |
| `pwm_acknowledge_irq`         | 1 STR  | ~6      | write-1-to-clear       |
| `pwm_set_freq_hz`             | 2 STR  | ~30-50  | one UDIV               |
| `pwm_set_gpio_function`       | 2 STR  | ~16     | PADS CLR + IO CTRL     |
| `pwm_resets_enable`           | 1 STR  | ~10+spin| spin on RESET_DONE     |

All slice-bit and IRQ-bit toggles use the atomic `+0x2000 SET` / `+0x3000
CLR` aliases so an ISR poking a sibling slice can never lose an enable bit
(no read-modify-write hazard).

## Servo cookbook

```
    @ 50 Hz, 1-2 ms pulse on GP15
    bl      pwm_init                            @ release reset

    movs    r0, #15
    bl      pwm_set_gpio_function

    movs    r0, #PWM_SLICE_FOR_GP15             @ 7
    movw    r1, #150                            @ DIV.int -> 1 us tick @ 150 MHz
    bl      pwm_set_clkdiv_int

    movs    r0, #PWM_SLICE_FOR_GP15
    movw    r1, #20000                          @ TOP -> 20 ms period
    bl      pwm_set_wrap

    movs    r0, #PWM_SLICE_FOR_GP15
    movs    r1, #PWM_CHAN_FOR_GP15              @ 1 (channel B)
    movw    r2, #1500                           @ 1.5 ms = neutral
    bl      pwm_set_chan_level

    movs    r0, #PWM_SLICE_FOR_GP15
    movs    r1, #1
    bl      pwm_set_enabled
```

Range: `r2 = 1000` -> full CCW, `r2 = 1500` -> centre, `r2 = 2000` -> full
CW.  See `examples/pwm_servo_demo.S` for the complete implementation that
sweeps every second.

## Wrap-IRQ wiring

PWM wrap interrupts come out on NVIC lines:

| Line                | Slices covered |
|---------------------|----------------|
| `PWM_IRQ_WRAP_0`= 8 | 0..11          |
| `PWM_IRQ_WRAP_1`= 9 | 0..11 (alt)    |

Both lines see all 12 slice wraps; the split is for letting the two cores
take separate wrap-IRQ vectors.  In `examples/pwm_irq_demo.S` we build a
private 64-entry vector table at runtime, install our handler at
slot `16 + 8 = 24`, point `VTOR` at the new table, and program
`NVIC_ISER0 |= (1 << 8)` to unmask the line.  The driver helpers
`pwm_irq_enable(slice, on)` and `pwm_acknowledge_irq(slice)` handle the
INTE / INTR plumbing.

## Tests

- **T1 (Unicorn).**  `tests/unicorn/test_pwm.py` injects calls into each
  public driver function and asserts on the resulting MMIO trace -- exact
  addresses, exact values, even access widths (STRH vs STR).  Also runs
  the fade demo end-to-end and checks slice 7 was enabled with the right
  DIV/TOP after clock bring-up.

- **T3 (Renode).**  `tests/renode/pwm.resc` loads `pwm_fade_demo.elf`,
  runs 1 s simulated, and asserts the peripheral logged
  `PWM slice 7 enabled` plus >=10 `PWM_CC_WRITE` events (proving the
  fade is animating).  The peripheral python is at
  `tests/renode/pwm_peripheral.py` (canonical) and inlined inside
  `tests/renode/rp2350.repl`'s PWM trailer block.
