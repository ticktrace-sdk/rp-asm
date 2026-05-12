# rp-asm

Pure-assembly SDK for the Raspberry Pi RP2350 (Cortex-M33).
**Motto: every cycle matters.**

No C compiler. The firmware is `arm-none-eabi-as` + `arm-none-eabi-ld`.
Python is only used host-side, for a UF2 packer and the test harness.

## Status

| Milestone | Scope                                                  | Status |
| --------- | ------------------------------------------------------ | ------ |
| v0.1      | startup, blinky, UART (SRAM image)                     | done   |
| M1        | test infra (Unicorn T1 + QEMU T2 + Renode T3)          | done   |
| M2        | XOSC + PLLs + CLOCKS @ 150 MHz, TICK, WATCHDOG, POWMAN | done   |
| M3        | GPIO/PADS (48 pins), TIMER0/1, SysTick, NVIC, DMA, PWM | done   |
| M4        | full PL011 UART, I2C0/1, SPI0/1, USB device CDC-ACM    | done   |
| M5        | SHA256, ADC, TRNG, PIO controller (no pioasm yet)      | done   |
| M6        | dual-core SIO + spinlocks + interpolators              | deferred |
| M7        | XIP flash boot, OTP, BOOTRAM, glitch detector          | deferred |
| M8        | example gallery + cycle-counting docs                  | deferred |

**Tests:** **270 T1** (Unicorn) + **3 T2** (QEMU) all green — every
public driver function has at least one register-trace assertion. T3
(Renode) green where renode is installed, cleanly skips otherwise.

| Tier | Coverage |
| ---- | -------- |
| T1   | 270 cases across 18 suites (smoke, v0.1 blinky, clocks, gpio, timer/systick, dma, pwm, uart, i2c, spi, usb, sha256, adc+trng, pio, trace, sched, spsc, sched_stats) |
| T2   | mps2-an505 sanity + ISA arithmetic + SysTick polled COUNTFLAG |
| T3   | 10 .resc scripts: blinky, clocks, gpio, timer, pwm, dma, uart loopback, i2c eeprom, spi loopback, usb controller bring-up |

**Image size:** the M2-default `build/blinky.uf2` (clock bring-up +
banner + blink) is 728 bytes of `.text`. Every peripheral demo lives in
`examples/` and builds to its own < 3 KB UF2.

## Build

```
sudo apt install binutils-arm-none-eabi python3
make            # build/blinky.uf2 + every examples/*.S
make test       # T1 + T2
make test-all   # + T3 (Renode)
make bench      # build/bench_*.uf2 (the comparison suite vs pico-sdk)
make bench-sizes # print image-size table (no flash needed)
```

## Flash

Hold **BOOTSEL** on the Pico 2 while plugging in USB. The bootrom mounts
as a USB MSC device; drag any `build/*.uf2` onto it.

Open a serial terminal at **115200 8N1** on UART0 TX (GP0 / pin 1).

## Layout

```
include/<periph>.inc       register maps + bitfields, one file per peripheral
src/<periph>.S             driver implementations
examples/<periph>_demo.S   self-contained example, builds to build/<periph>_demo.uf2
link/sram.ld               SRAM linker script (image at 0x20000000)
tools/uf2.py               bin -> UF2 packer (family rp2350-arm-s)
tests/unicorn/             T1 host harness + per-driver tests
tests/qemu/                T2 generic Cortex-M33 ISA smoke runner
tests/renode/              T3 RP2350 platform + per-driver .resc scripts
docs/                      per-peripheral cookbooks (see below)
Makefile                   AS / LD / OBJCOPY / UF2 + test umbrella
```

## Documentation

| Doc                  | What it covers                                         |
| -------------------- | ------------------------------------------------------ |
| `docs/apps.md`       | Build a Pico 2 app from scratch — function anatomy (prologue/body/epilogue), multi-file projects, IRQ handlers, Makefile wiring, debugging recipes |
| `docs/calling.md`    | AAPCS conventions, how drivers call each other, stack discipline, tail-calling, IRQ handler ABI, cycle costs |
| `docs/clocks.md`     | XOSC/PLL bring-up, clock tree, baud-recomputation hook |
| `docs/gpio.md`       | 48-pin GPIO + PADS, IRQ programming, ISO/OD erratum    |
| `docs/timer.md`      | TIMER0/1, SysTick, NVIC plumbing                       |
| `docs/dma.md`        | 16-channel DMA, sniffer, IRQ aggregators               |
| `docs/pwm.md`        | 12-slice PWM, freq/duty math, servo cookbook           |
| `docs/uart.md`       | PL011, IRQ + DMA modes, modem flow                     |
| `docs/i2c.md`        | DesignWare I2C, master + slave, HCNT/LCNT math         |
| `docs/spi.md`        | PL022, full duplex, DMA chained                        |
| `docs/usb.md`        | Device controller bring-up, CDC-ACM walkthrough        |
| `docs/sha256.md`     | Hardware SHA-256 + padding                             |
| `docs/adc.md`        | 8-channel ADC + temp sensor + DMA capture              |
| `docs/trng.md`       | TRNG bring-up + EHR drain                              |
| `docs/pio.md`        | PIO controller API + hand-encoding instructions        |
| `docs/trace.md`      | CoreSight DWT + ITM + TPIU + ETM for T4 hardware debug |
| `docs/benchmarking.md` | Benchmark suite + methodology for comparing against pico-sdk |
| `docs/sched.md`      | NVIC-priority scheduler (QV-style) — 5-cycle `task_post`, 0 stack-per-task, BASEPRI critical sections, batch `task_post_n` |
| `docs/spsc.md`       | Lock-free single-producer/single-consumer byte queue for ISR → soft-task pipelines |
| `docs/sched_stats.md`| Opt-in per-task DWT cycle accounting — task_create_traced + getters |

**New here?** Read `docs/apps.md` first — it walks you through writing
your first app top-to-bottom. Then `docs/calling.md` for the formal
calling-convention rules everything else assumes.

## Design notes

- **Atomic register aliases.** Every peripheral write uses the
  `+0x2000` SET / `+0x3000` CLR / `+0x1000` XOR aliases instead of
  read-modify-write. One `STR`, two cycles, no scratch, no ISR race.
- **`SIO_GPIO_OUT_XOR`** turns LED toggle into one 2-cycle store.
- **Clock tree.** The bootrom hands off at XOSC=12 MHz. M2's `clocks_init`
  ramps to `clk_sys = clk_peri = 150 MHz`, `clk_usb = clk_adc = 48 MHz`.
  UART baud divisors must be re-computed for clk_peri; the helper
  `clocks_post_pll_uart_baud_fixup` does this.
- **Pad isolation.** RP2350 pads come out of reset with `ISO=1` (datasheet
  §9.3.1). Every driver that touches a pin clears `ISO|OD` via the
  PADS_BANK0 CLR alias.
- **Pure-asm with AAPCS.** All drivers are plain Thumb-2 functions that
  follow AAPCS so they compose. See `docs/calling.md`.

## Test strategy (four tiers)

| Tier | Engine            | What it catches                          |
| ---- | ----------------- | ---------------------------------------- |
| T1   | Unicorn + Python  | Driver register sequences (deterministic, ms) |
| T2   | QEMU mps2-an505   | Generic Cortex-M33 ISA + vectors         |
| T3   | Renode + .repl    | End-to-end peripheral interaction        |
| T4   | Real Pico 2       | Ground truth — analog, USB enumeration, bootrom edges |

`make test` runs T1 + T2. `make test-all` adds T3. T4 is manual: flash
the relevant `build/*.uf2`, watch the serial console / logic analyser.

## Roadmap

- [ ] M6: dual-core bring-up (SIO FIFO handshake, spinlocks, interpolators)
- [ ] M7: XIP flash boot + custom boot2 + OTP read
- [ ] M8: example gallery — Larson scanner via PIO+DMA, USB CDC echo with
  hardware loopback, dual-core ping-pong
- [ ] `tools/pioasm.py` (deferred from M5-I)
- [x] Cycle-counting + on-chip printf via DWT/ITM/TPIU/ETM (`src/trace.S`)
- [ ] Pin a verified GPIO funcsel for SWO routing on Pico 2 silicon
- [ ] ETM address-range filtering (`etm_init_with_range`)
- [ ] DWT data watchpoints (`dwt_set_watchpoint`)
