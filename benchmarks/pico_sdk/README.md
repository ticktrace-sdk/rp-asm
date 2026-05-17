# pico-sdk paired benchmarks

These are the official-SDK C counterparts to `benchmarks/rp_asm/*.S`,
intended to produce numerically comparable measurements.

## Why not vendor pico-sdk as a submodule?

Build environment matters for these numbers (toolchain version, CMake
flags, LTO). Rather than pin a copy here, each benchmark documents
**which pico-sdk version was used** (`benchmarks/results.md` records
this) and ships a minimal `CMakeLists.txt` you can drop into the SDK
tree.

## Build recipe (Ubuntu/Debian)

```sh
sudo apt install gcc-arm-none-eabi cmake build-essential
git clone -b master --recurse-submodules https://github.com/raspberrypi/pico-sdk.git ~/pico-sdk
export PICO_SDK_PATH=~/pico-sdk
export PICO_PLATFORM=rp2350-arm-s
export PICO_BOARD=pico2

cd benchmarks/pico_sdk/bench_<name>
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release -DPICO_DEOPTIMIZED_DEBUG=0 ..
make -j
# Output: bench_<name>.uf2 + bench_<name>.elf
```

## Fairness rules (re-stated)

- Release build, LTO on by default in pico-sdk for these benches.
- Same clock: `set_sys_clock_khz(150000, true)` matches rp-asm's M2 default.
- Same hardware: Pico 2 (RP2350-A2), connected via picoprobe.
- The C harness emits the *same* `BENCH name=X metric=Y value=0xZZZZ`
  line format over UART0 so `benchmarks/run.sh` can parse either side
  identically.

## Measurement methodology

`benchmarks/run.sh <uf2>` flashes the UF2 (via `picotool load -fx`),
captures UART0 at 115200 8N1 for 5 s, greps `^BENCH ` lines, and
stuffs them into a JSON blob. Pair two runs by name and produce a
markdown delta table.

The `bench_minimum` and `bench_gpio_toggle` benches print their image
size off-target (just `arm-none-eabi-size`) and a runtime cycle count
respectively. The runtime numbers come from `DWT->CYCCNT` on both
sides — pico-sdk users get to it via `time_us_32()` (which is via
TIMER0, slow) OR directly with:

```c
#include "hardware/structs/dwt.h"
*((uint32_t*)0xE000EDFC) |= (1u << 24);   // DEMCR.TRCENA
dwt_hw->ctrl |= 1;                          // CYCCNTENA
uint32_t t0 = dwt_hw->cyccnt;
// workload
uint32_t cycles = dwt_hw->cyccnt - t0;
```

The C side of every bench in this directory uses the direct DWT
access for fairness — going through `time_us_32()` would add ~30
cycles of overhead per sample that the rp-asm side doesn't pay.
