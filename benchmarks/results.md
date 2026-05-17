# Benchmark results

Scoreboard for `benchmarks/`.  Update this file when you collect new
numbers from real Pico 2 hardware.

## Environment

| Knob              | Setting                                           |
| ----------------- | ------------------------------------------------- |
| Board             | TBD (Raspberry Pi Pico 2, silicon rev TBD)        |
| Probe             | TBD                                               |
| rp-asm commit     | TBD                                               |
| pico-sdk version  | TBD (`git describe --tags --always` in $PICO_SDK_PATH) |
| arm-none-eabi-gcc | TBD (`arm-none-eabi-gcc --version`)               |
| Date              | TBD                                               |

Replace TBD values when running the suite.

## Image size

Measured from `arm-none-eabi-size build/bench_<name>.elf`. The "text"
column is `.text + .rodata` from `arm-none-eabi-size -d`.

| Bench               | rp-asm text (B) | pico-sdk text (B) | rp-asm wins by |
| ------------------- | --------------: | ----------------: | -------------: |
| `bench_minimum`     | **224**         | TBD               | TBD            |
| `bench_gpio_toggle` | **1092**        | TBD               | TBD            |
| `bench_dma_memcpy`  | **1176**        | TBD               | TBD            |
| `bench_irq_latency` | **1432**        | TBD               | TBD            |
| `bench_sha256_64k`  | **~600** (excl. 64 KiB payload) | TBD             | TBD            |

The rp-asm numbers are reproducible right now with
`make bench-sizes`.

## Runtime (cycle counts at clk_sys = 150 MHz)

To be filled in from `benchmarks/run.sh` output.

| Bench               | Metric                 | rp-asm   | pico-sdk | Ratio |
| ------------------- | ---------------------- | -------- | -------- | ----- |
| `bench_gpio_toggle` | `cycles_per_iter_x256` | TBD      | TBD      | TBD   |
| `bench_sha256_64k`  | `cycles_total`         | TBD      | TBD      | TBD   |
| `bench_sha256_64k`  | `mbps_x100`            | TBD      | TBD      | TBD   |
| `bench_dma_memcpy`  | `dma_cycles`           | TBD      | TBD      | TBD   |
| `bench_dma_memcpy`  | `cpu_cycles`           | TBD      | TBD      | TBD   |
| `bench_irq_latency` | `min_cycles`           | TBD      | TBD      | TBD   |
| `bench_irq_latency` | `avg_cycles`           | TBD      | TBD      | TBD   |

## Predictions (to be verified)

These are what we expect to see based on `objdump` cycle counts and
the architecture of each path. Once real numbers come in, these get
crossed out or amended.

- `bench_gpio_toggle` cycles per iter: rp-asm ≈ 8, pico-sdk ≈ 8 with
  LTO (the leaf is the same `STR`). Gap should be small.
- `bench_sha256_64k` MB/s × 100: both ≈ 13000 (the engine bottleneck).
- `bench_dma_memcpy` `dma_cycles`: tie. `cpu_cycles`: tie.
- `bench_irq_latency` `min_cycles`: rp-asm ≈ 12 (hardware floor),
  pico-sdk ≈ 17–20 (the `__isr` wrapper).
- `bench_minimum` size: rp-asm 224 B, pico-sdk ~6–10 KiB.

## How to repro

```sh
make bench && make bench-sizes
# rp-asm numbers in stdout

# pico-sdk side (one-time)
export PICO_SDK_PATH=~/pico-sdk
for d in benchmarks/pico_sdk/bench_*/; do
    (cd "$d" && mkdir -p build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j)
done

# Capture runtime numbers (per bench)
benchmarks/run.sh build/bench_gpio_toggle.uf2 /dev/ttyACM0 5 > rp_asm_gpio.txt
benchmarks/run.sh benchmarks/pico_sdk/bench_gpio_toggle/build/bench_gpio_toggle.uf2 /dev/ttyACM0 5 > picosdk_gpio.txt
# diff -u rp_asm_gpio.txt picosdk_gpio.txt
```
