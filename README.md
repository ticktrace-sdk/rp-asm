# ticktrace

[www.ticktrace.io](www.ticktrace.io)

Pure-assembly firmware SDK for the Raspberry Pi RP2350 (Cortex-M33).  
**Every cycle matters.**

No C compiler required. Firmware is assembled with `arm-none-eabi-as` and linked with `arm-none-eabi-ld`. The result is a UF2 you drag onto the Pico 2 — or flash in one command with [ticktrace Studio](https://github.com/ticktrace-sdk/ticktrace-studio).

## What's included

**Peripheral drivers** — each is a plain Thumb-2 AAPCS function you call directly from your assembly:

| Peripheral | What you get |
|------------|-------------|
| GPIO / PADS | 48-pin control, IRQ, pad isolation |
| UART | Full PL011, 115200 8N1 out of the box |
| I2C | DesignWare I2C0/1, master + slave |
| SPI | PL022, full duplex, DMA chained |
| USB | Device CDC-ACM — plug in and get a serial port |
| DMA | 16-channel, mem-to-mem and peripheral |
| PWM | 12-slice, freq/duty helpers, servo cookbook |
| Timers | TIMER0/1, SysTick, NVIC plumbing |
| PIO | Hand-encoded programs, SM control |
| ADC | 8-channel + on-chip temperature sensor |
| SHA-256 | Hardware accelerated |
| TRNG | Hardware random number generator |
| Multicore | Dual-core launch, SIO FIFO, hardware spinlocks, interpolators |
| Flash / XIP | QMI tuning, OTP reads, BOOTSEL trick |
| Scheduler | NVIC-priority cooperative scheduler + lock-free ISR→task queue |
| Trace | DWT cycle counter, ITM/TPIU/ETM for on-hardware profiling |
| C bridge | Write your app in C; drivers stay assembly |
| Rust bridge | `no_std` Rust apps via `rp-asm-sys` crate |

**51 examples** in `examples/` — one per peripheral, each builds to its own UF2.

**Tests:** 283 T1 (Unicorn emulator) + QEMU ISA smoke tests + Renode platform tests, all green. Every public driver function has at least one register-trace assertion.

## Quickstart

### With Docker (Mac / Windows / Linux — no install)

```sh
docker run --rm -v "$PWD":/workspace ghcr.io/ticktrace-sdk/sdk:slim
```

That builds `blinky.uf2` and every example into `./build/`. Same command, same result on every platform — no toolchain to install.

To run the test suite (T1 Unicorn + T2 QEMU + Go tool tests):

```sh
docker run --rm -v "$PWD":/workspace ghcr.io/ticktrace-sdk/sdk:full make test
```

Linux users whose UID isn't 1000 should add `--user $(id -u):$(id -g)` so build artefacts aren't root-owned.

### Native (Linux)

```sh
sudo apt install binutils-arm-none-eabi python3 python3-venv
make pydeps   # one-time: create .venv and install test dependencies
make          # builds blinky.uf2 + all examples
make test     # run emulator tests
```

### GUI (any platform)

[ticktrace Studio](https://github.com/ticktrace-sdk/ticktrace-studio) is a one-download GUI that handles the toolchain, builds, and flashes the Pico for you. Pick a recipe from the catalog, click **Build & Flash**, done.

## Flash

Hold **BOOTSEL** on your Pico 2 while plugging in USB. The board mounts as a USB drive — drag any `.uf2` onto it.

Two image variants are available for every example:

| File | Where it runs | Survives power loss? |
|------|---------------|----------------------|
| `build/<name>.uf2` | SRAM at `0x20000000` | No — fast iteration |
| `build/<name>_flash.uf2` | Flash at `0x10000000` | Yes — shipped firmware |

```sh
make build/blinky_flash.uf2          # build a specific flash image
make build/<example>_flash.uf2       # any example
```

After flashing, open a serial terminal at **115200 8N1** on UART0 TX (GP0, pin 1).

## ticktrace Studio

For a GUI with a catalog browser, one-click build and flash, and a memory map view, see [ticktrace Studio](https://github.com/ticktrace-sdk/ticktrace-studio).

## Repository layout

```
include/<periph>.inc       register maps and bitfields, one file per peripheral
src/<periph>.S             driver implementations
examples/<periph>_demo.S   self-contained examples
link/sram.ld               SRAM linker script
link/flash.ld              flash linker script
tools/uf2.py               bin → UF2 packer
tests/                     T1 (Unicorn), T2 (QEMU), T3 (Renode) test suites
docs/                      per-peripheral guides
Makefile                   build + test umbrella
```

## Documentation

Start with `docs/apps.md` — it walks through writing your first app from scratch. Then `docs/calling.md` for the AAPCS calling conventions everything else follows.

| Doc | Covers |
|-----|--------|
| `docs/apps.md` | First app: function anatomy, multi-file projects, IRQ handlers, Makefile wiring |
| `docs/boot.md` | Bootrom → `_reset` → `main`, SRAM vs flash, debugging a bring-up hang |
| `docs/calling.md` | AAPCS conventions, stack discipline, IRQ handler ABI, cycle costs |
| `docs/clocks.md` | XOSC/PLL bring-up, clock tree, baud recomputation |
| `docs/gpio.md` | 48-pin GPIO + PADS, IRQ, ISO/OD erratum |
| `docs/timer.md` | TIMER0/1, SysTick, NVIC plumbing |
| `docs/nvic.md` | NVIC: enable, install, pending, priority |
| `docs/dma.md` | 16-channel DMA, sniffer, IRQ aggregators |
| `docs/pwm.md` | 12-slice PWM, freq/duty math, servo cookbook |
| `docs/uart.md` | PL011, IRQ + DMA modes |
| `docs/i2c.md` | DesignWare I2C, master + slave, HCNT/LCNT math |
| `docs/spi.md` | PL022, full duplex, DMA chained |
| `docs/usb.md` | Device controller bring-up, CDC-ACM walkthrough |
| `docs/sha256.md` | Hardware SHA-256 + padding |
| `docs/adc.md` | 8-channel ADC + temp sensor + DMA capture |
| `docs/trng.md` | TRNG bring-up |
| `docs/pio.md` | PIO controller API + hand-encoding instructions |
| `docs/trace.md` | CoreSight DWT + ITM + TPIU + ETM for hardware profiling |
| `docs/sched.md` | NVIC-priority scheduler: task_post, BASEPRI critical sections |
| `docs/spsc.md` | Lock-free ISR → task byte queue |
| `docs/c_bridge.md` | C apps with assembly drivers |
| `docs/rust_bridge.md` | `no_std` Rust apps with assembly drivers |
| `docs/benchmarking.md` | Benchmark suite vs pico-sdk |

## Design notes

- **Atomic aliases.** Every peripheral write uses the `+0x2000` SET / `+0x3000` CLR / `+0x1000` XOR aliases — one `STR`, two cycles, no scratch register, no ISR race.
- **Pad isolation.** RP2350 pads reset with `ISO=1`. Every driver that touches a pin clears `ISO|OD` via the PADS_BANK0 CLR alias.
- **AAPCS throughout.** All drivers are plain Thumb-2 functions that compose freely. Drivers can be called from C or Rust without a wrapper layer.
- **Image size.** `build/blinky.uf2` is ~1.2 KB of `.text` with the full default driver set. Each example UF2 is under 4 KB because it links only the drivers it needs.

## License

AGPL-3.0-or-later. A commercial license is available from Amken LLC — see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).
