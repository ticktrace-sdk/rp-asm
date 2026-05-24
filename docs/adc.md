# ADC 

RP2350 has an 8-channel, 12-bit SAR ADC (RP2040 had 4 channels). Sample
rate up to 500 kS/s.

Driver: `src/adc.S`. Defs: `include/adc.inc`. Base: `0x400a0000`.
RESETS bit: `0`. Needs `clk_adc = 48 MHz` (M2's `clocks_init` sets this).

## Channel map

| AINSEL | Source                            |
| -----: | --------------------------------- |
| 0      | GP40                              |
| 1      | GP41                              |
| 2      | GP42                              |
| 3      | GP43                              |
| 4      | GP44                              |
| 5      | GP45                              |
| 6      | GP46                              |
| 7      | GP47                              |
| 8      | internal temperature sensor       |

Channels 0–7 require the corresponding pad to have `IE=0, OD=0, no pulls`.
Use `gpio_disable_pulls(pin)` plus a direct write of `0` (clearing `IE`)
on the pad, OR keep the pad at reset state and just don't reconfigure it.

## API

```
adc_init                                  RESETS clear; CS.EN=1; wait READY
adc_select_input(r0=ch)                   CS.AINSEL = ch (preserves other bits)
adc_set_temp_sensor_enabled(r0=on)        CS.TS_EN
adc_set_round_robin(r0=mask)              CS.RROBIN[23:16]
adc_set_clkdiv(r0=int, r1=frac)           DIV = (int<<8) | frac
adc_read() -> r0                          START_ONCE, spin READY, return RESULT
adc_run(r0=on)                            CS.START_MANY
adc_fifo_setup(en, dreq_en, thresh, shift) FCS = combined
adc_fifo_get_blocking() -> r0             spin FCS.EMPTY clear, pop FIFO
adc_fifo_drain                            drain in software
```

## Quick start: temperature sensor

```asm
    bl      adc_init
    movs    r0, #1
    bl      adc_set_temp_sensor_enabled
    movs    r0, #8                  @ AINSEL = temp sensor
    bl      adc_select_input

.Lloop:
    bl      adc_read                @ r0 = 12-bit raw count
    @ Convert off-board: V = 3.3 * raw / 4095; T_C = 27 - (V - 0.706) / 0.001721
    @ ... print, delay, repeat
```

## Quick start: DMA capture at 500 kS/s

Driver `adc_fifo_setup(en=1, dreq_en=1, thresh=4, shift=0)` plus
`adc_run(1)` produces a steady stream of 32-bit FIFO entries; pair with a
DMA channel paced by `DREQ_ADC = 36` (defined in `include/dma.inc`) and
write the result into SRAM. See `examples/adc_temp_demo.S` for the simpler
one-shot pattern.

## Sample-rate math

`Tsample = DIV / clk_adc + 96 cycles`. With `clk_adc = 48 MHz` and
`DIV = 0` (continuous), `Tsample = 2 µs`, giving 500 kS/s. Increase
`DIV.INT` to slow the engine down for power-sensitive applications.

## Build artefacts

- `build/adc_temp_demo.uf2`: prints `raw=NNNN\r\n` every ~250 ms.

## T1 tests

`tests/unicorn/test_adc_trng.py::test_adc_*` (4 cases):

- `adc_init` clears RESETS bit 0 and enables CS.
- `adc_set_clkdiv(96, 0x12)` packs `(96<<8) | 0x12` into DIV.
- `adc_select_input(3)` sets AINSEL=3, preserves EN.
- `adc_read` writes CS.START_ONCE and polls READY before returning RESULT.
