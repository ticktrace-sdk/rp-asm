# Benchmarking ticktrace vs pico-sdk

This is how we put numbers on "every cycle matters".  The benchmark
suite lives in `benchmarks/`, builds on both sides with the same shape,
and emits parseable `BENCH …` lines so a host script can tabulate
results without any per-bench glue.

## Layout

```
benchmarks/
    rp_asm/
        bench_lib.S              shared output / init helpers
        bench_minimum.S          smallest blinker
        bench_gpio_toggle.S      100k× gpio_toggle, DWT cycles
        bench_sha256_64k.S       hash 64 KiB
        bench_dma_memcpy.S       DMA vs CPU 16 KiB copy
        bench_irq_latency.S      TIMER alarm -> ISR delta, 32 samples
    pico_sdk/
        README.md                build recipe with pico-sdk
        bench_*/main.c           paired C source
        bench_*/CMakeLists.txt   minimal pico-sdk build glue
    run.sh                       flash + capture BENCH lines from UART0
    results.md                   running scoreboard with observed numbers
```

## Build (ticktrace side)

```
make bench               # build every benchmarks/rp_asm/bench_*.uf2
make bench-sizes         # print image-size table (no flash needed)
```

The `bench` target follows the same examples auto-discovery pattern
already in use for `examples/*.S`, plus links each bench against
`benchmarks/rp_asm/bench_lib.S` for the shared `bench_emit` /
`bench_standard_init` helpers.

## Build (pico-sdk side)

`benchmarks/pico_sdk/README.md` has the full recipe. TL;DR:

```sh
export PICO_SDK_PATH=~/pico-sdk
export PICO_BOARD=pico2
cd benchmarks/pico_sdk/bench_gpio_toggle
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j
```

Every C bench emits the exact same `BENCH name=… metric=… value=0x…`
format that the ticktrace side does, so `benchmarks/run.sh` is
SDK-agnostic.

## Run on hardware

```
benchmarks/run.sh build/bench_gpio_toggle.uf2 /dev/ttyACM0 5
# BENCH name=gpio_toggle metric=cycles_total value=0x000c350f
# BENCH name=gpio_toggle metric=cycles_per_iter_x256 value=0x000007ff
```

Then flip to the pico-sdk side, repeat, and diff.

## Methodology

### Output format

One line per measurement:

```
BENCH name=<bench>  metric=<metric>  value=0x<8 hex digits>
```

Hex keeps the print path to ~60 bytes of code on the ticktrace side
(no `/-by-10` formatting routines). The "value" field is always a
32-bit unsigned cycle count or fixed-point ratio, never a float;
floats would tilt the comparison against pico-sdk for no good
reason.

### Fairness rules

| Rule                                       | Why                                              |
| ------------------------------------------ | ------------------------------------------------ |
| Same hardware: Pico 2 (RP2350-A2)          | Eliminates silicon-rev differences               |
| Same clock: `clk_sys = 150 MHz`            | Both M2 (`pll_sys_150_mhz`) and pico-sdk's `set_sys_clock_khz(150000, true)` |
| pico-sdk release build, `-O3 -flto -DNDEBUG` | Debug builds add `assert()` calls, ~3× cycles per public API |
| Direct `DWT->CYCCNT` read on both sides    | Avoids the ~30-cycle `time_us_32` overhead       |
| Steady-state only for throughput numbers   | Init costs amortise to nothing on long runs      |
| ISR bodies marked `__not_in_flash_func()` (C side) | Keeps the C bench out of XIP wait states for parity with the ticktrace side which is SRAM-resident |

### What we expect to win, where we expect to lose

| Category                | Likely winner | Why                                            |
| ----------------------- | ------------- | ---------------------------------------------- |
| Minimum image size      | ticktrace        | No crt0, no stdio, no `_init_array` machinery  |
| Boot to first user code | ticktrace        | No `.data` copy, no BSS zero, no stdio init    |
| Per-call leaf cycles    | tie or ticktrace | Both end up at the same `STR` eventually; SDK pays wrapper overhead in non-LTO builds |
| Throughput (SHA, DMA)   | tie           | Both bottleneck on the peripheral, not the CPU |
| IRQ entry latency       | small ticktrace  | SDK's `__isr` wrapper adds a few cycles        |
| Toolchain wall-clock    | ticktrace by 30–100× | No C compiler, no CMake configure step         |

### What we will lose at (and shouldn't pretend otherwise)

- **Portability.** pico-sdk runs on RP2040 *and* RP2350, and on every
  Pico variant.  We target Pico 2 + RP2350-Arm-Secure specifically.
- **Ecosystem.**  TinyUSB, lwIP, Bluetooth, WiFi, RTOSes all integrate
  with pico-sdk out of the box.  We have UART, USB CDC-ACM echo, and
  vibes.
- **Asserts / debug builds.**  pico-sdk's debug builds catch a category
  of bugs (bad pin number, peripheral not in reset, etc.) that we
  cheerfully don't.  That's a deliberate trade-off, not a win.

### Caveats

- Image-size numbers will look more flattering to ticktrace than reality
  because pico-sdk pulls in `stdio` whether you use it or not.  A
  fairer version of `bench_minimum` would strip stdio on the SDK
  side; we don't, because "I want printf" is the default expectation.
- Some metrics (boot time, IRQ entry-to-pin-toggle) require a logic
  analyser to measure to nanosecond precision.  The DWT-based
  versions are an in-band approximation that compares apples-to-apples
  if you don't have one.
- Wall-clock build time depends heavily on your machine and pico-sdk
  caching state.  We report cold-cache numbers.

## What's in the suite today

| Bench               | ticktrace `.text` (bytes) | What it measures                       |
| ------------------- | ---------------------: | -------------------------------------- |
| `bench_minimum`     | 224                    | Image size of "blink GP25, nothing else" |
| `bench_gpio_toggle` | 1092                   | 100k × `gpio_toggle(25)`, DWT cycles   |
| `bench_dma_memcpy`  | 1176                   | 16 KiB SRAM→SRAM via DMA + CPU loop    |
| `bench_irq_latency` | 1432                   | TIMER0 alarm → ISR delta, 32 samples   |
| `bench_sha256_64k`  | 66880 (64 KiB payload) | SHA-256 of 64 KiB, cycles + MB/s×100   |

`bench_sha256_64k`'s "text" is dominated by the 64 KiB `.rodata`
payload; the actual code is ~600 bytes.

## Roadmap

- [ ] Capture observed numbers on real Pico 2 and fill in
      `benchmarks/results.md`.
- [ ] Add `bench_uart_tx_throughput` (push 16 KiB out UART0 at 1 Mbps,
      report wall-clock cycles).
- [ ] Add `bench_pwm_update_rate` (change PWM duty in a tight loop).
- [ ] Add `bench_boot_to_main` with a GPIO pulse from `_reset` to the
      first user instruction for logic-analyser capture.
- [ ] `make compare` target that runs both SDKs back-to-back and
      emits a markdown diff table.
