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
| M6        | dual-core launch, SIO FIFO mailbox, hardware spinlocks, interpolators | done |
| M7        | XIP flash boot config (QMI clkdiv tune) + OTP read + bootrom services (1200-baud BOOTSEL trick + `rom_reset_to_bootsel`); glitch detector deferred | partial |
| M8        | example gallery + cycle-counting docs                  | deferred |

**Tests:** **278 T1** (Unicorn) + **3 T2** (QEMU) all green — every
public driver function has at least one register-trace assertion. T3
(Renode) green where renode is installed, cleanly skips otherwise.

| Tier | Coverage |
| ---- | -------- |
| T1   | 278 cases across 19 suites (smoke, v0.1 blinky, clocks, gpio, timer/systick, dma, pwm, uart, i2c, spi, usb, sha256, adc+trng, pio, trace, sched, spsc, sched_stats, c_bridge) |
| T2   | mps2-an505 sanity + ISA arithmetic + SysTick polled COUNTFLAG |
| T3   | 10 .resc scripts: blinky, clocks, gpio, timer, pwm, dma, uart loopback, i2c eeprom, spi loopback, usb controller bring-up |

### Hardware verification (T4, manual)

Status of each `src/<peripheral>.S` driver on a real Pico 2 (RP2350-A2).
"Direct" = a `build/<name>_flash.uf2` exercises the driver's intended
feature.  "Indirect" = the driver is called by a directly-verified
image but its primary feature isn't observed.  "Not yet" = only the
lower tiers (T1/T2/T3) cover it.

| Driver        | Status         | Verified via / notes                                                |
| ------------- | -------------- | ------------------------------------------------------------------- |
| `startup.S`   | ✅ Direct      | every flash UF2 — M33 prologue, vector relocation, RESETS, `b main` |
| `xosc.S`      | ✅ Direct      | `blinky_flash` — 12 MHz XOSC stable                                 |
| `pll.S`       | ✅ Direct      | `blinky_flash` — `pll_sys` @ 150 MHz, `pll_usb` @ 48 MHz            |
| `clocks.S`    | ✅ Direct      | `blinky_flash` — `clk_sys` / `clk_peri` / `clk_usb` routing         |
| `gpio.S`      | ✅ Direct      | `blinky_flash` — GP25 LED toggle observed                           |
| `uart.S`      | ✅ Direct      | `blinky_flash` — banner @ 115200 8N1 on UART0 TX                    |
| `usb.S`       | ✅ Direct      | `usb_cdc_echo_demo_flash` — full enumeration + bidirectional CDC echo |
| `timer.S`     | ✅ Direct      | `timer_usb_demo_flash` — TIMER0 ALARM0 IRQ fires at 1 MHz/500000-us cadence; ISR re-arms; ISR also reports via USB CDC |
| `tick.S`      | ✅ Direct      | `timer_usb_demo_flash` — `t=` increments by 500000 per 500 ms, confirming the 1 MHz tick rate set up by `tick_init` |
| `nvic.S`      | ✅ Direct      | `timer_usb_demo_flash` (line 0) + `usb_cdc_echo_demo_flash` (line 14) — install + enable for two different IRQ lines, both vector to their handlers |
| `systick.S`   | ✅ Direct      | `systick_usb_demo_flash` — 100 ms SysTick @ proc clock, vec[15] patch, ISR fires at 5× the main-loop heartbeat rate as expected |
| `pwm.S`       | ✅ Direct      | `pwm_usb_demo_flash` — slice 4 ch B (GP25), DIV/TOP/CC/EN, software triangle fade with visible LED breathing + CDC level stream |
| `dma.S`       | ✅ Direct      | `dma_usb_demo_flash` — 256-word mem-to-mem copy with `DMA_CTRL_MEM2MEM_WORD`, BUSY spin, word-wise compare reports `dma OK iter=N` each second |
| `adc.S`       | ✅ Direct      | `data_usb_demo_flash` — temp sensor (channel 8) reads `adc temp=N` each iteration |
| `sha256.S`    | ✅ Direct      | `data_usb_demo_flash` — `sha256_compute("abc",3,...)` returns canonical NIST FIPS-180-4 digest `ba7816bf8f01cfea...f20015ad` |
| `sched.S`     | ✅ Direct      | `sched_usb_demo_flash` — TIMER0 alarm posts task via NVIC, t_consumer drains SPSC + prints |
| `spsc.S`      | ✅ Direct      | `sched_usb_demo_flash` — ISR pushes counter byte, task pops; `byte=N` increments monotonically with iter |
| `sched_stats.S` | ✅ Direct    | `sched_usb_demo_flash` — `inv=N cyc=NNNNN` (cyc grows by ~2500 per task fire, matches expected task-body cycle cost) |
| `trace.S`     | ✅ Direct      | `trace_usb_demo_flash` — DWT cycle counter; busy_loop_3M reads 3000007 (3M + 7 cycle overhead) |
| `watchdog.S`  | ✅ Direct      | `watchdog_usb_demo_flash` — `watchdog_enable` + `watchdog_feed` + intentional starve; observe kick loop, then chip-level reset (LED stops, USB re-enumerates). Required correcting `CTRL.ENABLE` bit (was 31 = TRIGGER, datasheet says 30) and setting `PSM_WDSEL = 0x01FFFFF3` |
| `pio.S`       | ✅ Direct      | `pio_usb_demo_flash` — 9-instruction hand-encoded blink program at PIO0 SM0, `SET PINDIRS,1` + toggle loop, visible LED at ~1 Hz; required two fixes: `pio_sm_set_wrap` mask (bits 13-15 of WRAP_TOP were stuck at reset value) and adding `SET PINDIRS` to the program so the SM drives the pad |
| `trng.S`      | ✅ Direct      | `data_usb_demo_flash` — fresh 32-bit value each iteration after fixing `trng_get_random_word` to drain all 6 EHR words before ICR (CryptoCell EHR only refills once fully consumed) |
| `multicore.S` | ✅ Direct      | `multicore_usb_demo_flash` — core 0 owns USB CDC (`c0 alive N` heartbeat), core 1 owns GP25 LED (2 Hz toggle). Both observables run concurrently, confirming the SIO FIFO launch handshake (`0,0,1,vtable,sp,entry`) and core 1's independent M33 prologue. |
| `spinlock.S`  | ✅ Direct      | `multicore_full_usb_demo_flash` — `shared_counter` incremented by core 1 under `spin_lock(0)`, snapshotted by core 0 under same lock; monotonic across host observations |
| `interp.S`    | ✅ Direct      | `multicore_full_usb_demo_flash` — INTERP0 lane 0 with `BASE0=1000`, `ACCUM0 = shared_counter`, `MASK_MSB=31`; PEEK returns `counter + 1000` exactly each line |
| `qmi.S`       | ✅ Direct      | `qmi_usb_demo_flash` — `qmi_set_clkdiv(2)` (75 MHz SCK) drops 16 KiB XIP→SRAM cold-cache copy from ~34k cycles to ~27k cycles (1.2× speedup); function executes from SRAM via the new `.ramfunc` section to avoid pulling QSPI config out from under our own instruction fetch |
| `otp.S`       | ✅ Direct      | `otp_usb_demo_flash` — reads CHIPID0..3 (`0x3d296d86_f94b7b5c` on the test board), RANDID0..3 (low half populated, high half 0 — some batches), FLASH_DEVINFO (0 on the test board); all reads deterministic across iterations |
| `bootrom.S`   | 🟡 To verify   | `bootsel_usb_demo_flash` — send `b` via CDC, or `stty -F /dev/ttyACM0 1200` from the host, to invoke `rom_reset_to_bootsel`; device disconnects and re-enumerates as `RPI-RP2` mass-storage |
| BOOTRAM       | n/a            | per RP2350 datasheet §4.3 the 1 KiB SRAM at 0x400E0000 is bootrom-owned and not application-writable; `include/bootram.inc` exposes only the hardware register offsets (`WRITE_ONCE0/1`, `BOOTLOCK_STAT`, `BOOTLOCK0..7` at +0x800) for future use |
| `powman.S`    | ❌ Not yet     | linked into DRIVER_SRC but no caller in the M2 path                 |
| `i2c.S`       | ❌ Not yet     | T1/T3 only — needs external I2C peripheral                          |
| `spi.S`       | ❌ Not yet     | T1/T3 only — needs external SPI peripheral                          |
| `ssbl.S` + `tsbl_bypass.S` + `crc32.S` | ✅ Direct | `firmware_blinky.uf2` — full FSBL→SSBL→TSBL→app chain on real silicon. SSBL CRC32-validates the 24 KiB TSBL slot, TSBL CRC32-validates the app slot, blinky runs end-to-end. Proves all three handoffs (SP/PC/VTOR transitions) work as designed. |

When a new driver is hardware-verified, update the row and reference
the UF2 (and any debug observation — UART log, scope trace, dmesg
quote) in the commit message.

**Language bridges (T4 verified):**

| Bridge | UF2 | What it proves |
| ------ | --- | -------------- |
| C      | `build/hello_c_flash.uf2`    | C→asm AAPCS calls work on real silicon; `_c_runtime_init` zeroes `.bss`; LED toggles at the expected rate driven from `main()` written in C. |
| Rust   | `build/hello_rust_flash.uf2` | Rust→asm FFI works on `thumbv8m.main-none-eabi`; `librp_asm.a` static archive links cleanly into `no_std` binary; LED toggles at the expected rate driven from `fn main()` written in Rust. |

**Image size:** the M2-default `build/blinky.uf2` (clock bring-up +
banner + blink) is 728 bytes of `.text`. Every peripheral demo lives in
`examples/` and builds to its own < 3 KB UF2.

## Build

```
sudo apt install binutils-arm-none-eabi python3 python3-venv
make pydeps     # one-shot: create .venv + install unicorn/pyelftools/pytest
make            # build/blinky.uf2 + every examples/*.S (SRAM-resident, for tests)
make test       # T1 + T2
make test-all   # + T3 (Renode)
make bench      # build/bench_*.uf2 (the comparison suite vs pico-sdk)
make bench-sizes # print image-size table (no flash needed)
```

## Flash

Both UF2 variants now boot on hardware.  Pick the one that matches
your iteration loop:

| `build/<name>.uf2`          | SRAM-resident at `0x20000000`. Volatile (loses the program on power loss). Useful when you want quick A/B turnaround on hardware. |
| `build/<name>_flash.uf2`    | XIP flash at `0x10000000`. Survives power cycles. Default for shipped firmware. |

```
make build/blinky.uf2               # SRAM variant
make build/blinky_flash.uf2         # flash variant
make build/<example>_flash.uf2      # any example, flash variant
```

`tools/uf2.py` now picks the right UF2 family ID automatically from
the load address (`0xE48BFF57` RP2XXX_ABSOLUTE for SRAM,
`0xE48BFF59` RP2350_ARM_S for flash).  Earlier versions of the
packer hard-coded the flash family for SRAM images, which the
bootrom silently rejected.  See [docs/boot.md](docs/boot.md) for
the full bring-up story.

Hold **BOOTSEL** on the Pico 2 while plugging in USB. The bootrom
mounts as a USB MSC device; drag either `.uf2` onto it.

Open a serial terminal at **115200 8N1** on UART0 TX (GP0 / pin 1).

## Layout

```
include/<periph>.inc       register maps + bitfields, one file per peripheral
src/<periph>.S             driver implementations
examples/<periph>_demo.S   self-contained example, builds to build/<periph>_demo.uf2
link/sram.ld               SRAM linker script (image at 0x20000000, for tests)
link/flash.ld              flash linker script (image at 0x10000000, for hardware)
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
| `docs/boot.md`       | Bootrom → `_reset` → `main`: M33 prologue, vector relocation, SRAM-vs-flash, how to debug a hardware bring-up hang |
| `docs/calling.md`    | AAPCS conventions, how drivers call each other, stack discipline, tail-calling, IRQ handler ABI, cycle costs |
| `docs/clocks.md`     | XOSC/PLL bring-up, clock tree, baud-recomputation hook |
| `docs/gpio.md`       | 48-pin GPIO + PADS, IRQ programming, ISO/OD erratum    |
| `docs/timer.md`      | TIMER0/1, SysTick, NVIC plumbing                       |
| `docs/nvic.md`       | NVIC helpers — enable / install / pending / priority   |
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
| `docs/c_bridge.md`   | Opt-in C bridge: write apps in C, drivers stay asm (branch `claude/c-rust-bridge`) |
| `docs/rust_bridge.md`| Opt-in Rust bridge: `no_std` Rust apps via `rp-asm-sys` crate (same branch) |

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
