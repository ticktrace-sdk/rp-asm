# Rust ecosystem via embedded-hal

The Rust bridge ([`docs/rust_bridge.md`](rust_bridge.md)) gets you
`unsafe extern "C"` access to every ticktrace driver. **This page is about
the layer above it**: `embedded-hal` trait implementations so that
thousands of existing Rust driver crates work over our asm core
without any modification.

> **Branch:** `claude/c-rust-bridge`.

## The two crates

### `rp-asm-hal`: embedded-hal 1.0 trait impls

Path: `rust_bridge/rp-asm-hal/`. Wraps `rp-asm-sys` in idiomatic types
and implements the major `embedded-hal` 1.0 traits:

| Trait | Wrapper | Notes |
| ----- | ------- | ----- |
| `digital::OutputPin`, `InputPin`, `StatefulOutputPin` | `Pin` | `Pin::output(25)` / `Pin::input(7)` |
| `i2c::I2c<SevenBitAddress>` | `I2cBus` | `I2cBus::new(idx, baud, sda, scl)` |
| `spi::SpiBus<u8>` | `Spi` | Pair with `embedded-hal-bus::ExclusiveDevice` for `SpiDevice` |
| `delay::DelayNs` | `Delay` | DWT cycle counter; `Delay::new(150_000_000)` |
| `pwm::SetDutyCycle` | `PwmChannel` | Per-channel handle |
| `embedded_io::Read`, `Write`, `core::fmt::Write` | `Uart` | `writeln!(uart, "{}", val)` works |

### `rp-asm-rt`: runtime helpers

Path: `rust_bridge/rp-asm-rt/`. Three pieces:

1. **Bump allocator** as `#[global_allocator]`. 32 KiB carved out of
   SRAM, no free path. Unlocks crates that need `alloc`.
2. **`entry!()` macro** that wraps a `fn() -> !` as the `extern "C" fn
   main` ticktrace's startup calls, with `_c_runtime_init` run first.
3. **`panic_blink()`** convenience for user `#[panic_handler]`s.

## What this unlocks

After ~500 LOC of bridge code, every embedded-hal 1.0 driver crate on
crates.io works against ticktrace without modification.

| Category | Example crates | What you get |
| -------- | -------------- | ------------ |
| Displays | `ssd1306`, `ssd1309`, `st7735`, `ili9341` | Drive any standard OLED/TFT |
| Graphics | `embedded-graphics`, `embedded-graphics-core` | Fonts, primitives, image rendering |
| Sensors | `bme280-rs`, `bmp180`, `mpu6050`, `lsm303`, `tmp102`, `mlx90614` | Temperature/humidity/IMU/IR sensors |
| Radio | `nrf24l01`, `lora-phy`, `cc1101` | Sub-GHz + 2.4 GHz radios |
| RFID/NFC | `mfrc522`, `pn532` | Card readers |
| LED strips | `ws2812-spi`, `smart-leds`, `apa102-spi` | Addressable LED arrays |
| Storage | `embedded-sdmmc`, `littlefs2` | SD cards and flash filesystems |
| Networking | `smoltcp` + an Ethernet driver | TCP/IP stack |
| Parsers | `nom`, `serde`, `serde_json`, `toml` | Data interchange |

## Quick start: drive an SSD1306 OLED

```toml
# rust_apps/your_app/Cargo.toml
[dependencies]
rp-asm-sys = { path = "../../rust_bridge/rp-asm-sys" }
rp-asm-hal = { path = "../../rust_bridge/rp-asm-hal" }
rp-asm-rt  = { path = "../../rust_bridge/rp-asm-rt" }
embedded-hal = "1.0"
ssd1306 = "0.9"
embedded-graphics = "0.8"
```

```rust
#![no_std]
#![no_main]

use embedded_graphics::{
    mono_font::{ascii::FONT_6X10, MonoTextStyle},
    pixelcolor::BinaryColor,
    prelude::*,
    text::Text,
};
use rp_asm_hal::I2cBus;
use rp_asm_sys as sys;
use ssd1306::{prelude::*, I2CDisplayInterface, Ssd1306};

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { rp_asm_rt::panic_blink() }

rp_asm_rt::entry!(app_main);

fn app_main() -> ! {
    unsafe {
        sys::xosc_init();
        sys::pll_sys_150_mhz();
        sys::pll_usb_48_mhz();
        sys::clocks_init();
        sys::gpio_led_init();
        sys::dwt_init();
    }

    let i2c = I2cBus::new(0, 400_000, 4, 5);
    let mut display = Ssd1306::new(
        I2CDisplayInterface::new(i2c),
        DisplaySize128x64,
        DisplayRotation::Rotate0,
    ).into_buffered_graphics_mode();
    display.init().unwrap();

    let style = MonoTextStyle::new(&FONT_6X10, BinaryColor::On);
    Text::new("ticktrace + ssd1306", Point::new(2, 12), style)
        .draw(&mut display).unwrap();
    display.flush().unwrap();

    loop { unsafe { sys::gpio_led_toggle() } }
}
```

That's the entire integration. Build with `make rust-apps`; works
exactly like `hello_rust`.

## Build sizes (release, opt-level="s", LTO on)

| App | `.text` | Notes |
| --- | ------: | ----- |
| `hello_rust` | 1040 B | No ecosystem deps, just calls rp-asm-sys |
| `bme280_demo` | 7624 B | Pulls `bme280-rs` from crates.io |
| `ssd1306_demo` | 10484 B | Pulls `ssd1306` + `embedded-graphics` + a font |

The ecosystem demos pay 7-10 KiB for the driver + graphics machinery
they're using. The asm drivers themselves are unchanged in cycle cost
because the embedded-hal trait calls dispatch directly to the same
`unsafe extern "C"` functions `hello_rust` calls.

## Comparison vs `rp-hal`

`rp-hal` is the established Rust HAL for RP2350. Both let you use the
same upstream driver crates. Differences:

| Property | rp-asm-hal | rp-hal |
| -------- | ---------- | ------ |
| Driver implementation | Hand-tuned asm | C-like Rust |
| `gpio_put` cycle cost | 4 cycles | ~4-6 (LTO-dependent) |
| `i2c_write_blocking` startup | ~30 cycles | similar |
| Boot time | ~150 cycles | thousands (cortex-m-rt) |
| Image size for "blink" | 728 B | 4-6 KiB |
| Async support | None today | Some via `embassy` |
| Maintainer-years of testing | weeks | years |

Use rp-hal if you want a battle-tested Rust-first experience.
Use rp-asm-hal if you want hand-tuned cycle counts and the asm core
also accessible from C / other-FFI in the same image.

## Limitations

1. **No async.** All trait impls are blocking. An `embassy-time` /
   `embassy-executor` integration would be ~200 LOC and a separate
   doc; not part of this milestone.
2. **No `embedded-hal-async` traits.** Same reason as above.
3. **`SpiDevice` not directly implemented.** Use `embedded-hal-bus`
   (the official adapter crate) to wrap an `Spi` bus + CS pin into a
   `SpiDevice`. One-liner in the user's `Cargo.toml`.
4. **`I2c` only `SevenBitAddress`.** 10-bit addressing is rare and our
   asm driver doesn't expose it.
5. **`Delay` polls DWT.** No `wfi`/timer-based deep sleep; the CPU
   spins. For low-power applications, use a TIMER0 alarm + the
   scheduler instead.
6. **Bump allocator never frees.** Crates that allocate-then-free
   repeatedly will leak. Swap in `linked_list_allocator` from
   crates.io if you need true reclamation.

## Going further

- **`embedded-hal-async`**: provide async versions of the same traits
  backed by IRQ-based completion notifications. Pairs naturally with
  our NVIC-priority scheduler; a `task_post` from an ISR can wake an
  `embassy` waker.
- **`embedded-storage`** for flash/EEPROM access once `M7` (XIP boot)
  lands.
- **`embedded-can`** if anyone adds a CAN peripheral driver.
- **`defmt` over ITM**: structured logging into a host-side viewer.
  ~50 LOC because we already have `itm_putw`.

## Examples in this repo

- `rust_apps/ssd1306_demo/`: text on a 128×64 OLED, refreshed with a
  counter
- `rust_apps/bme280_demo/`: temperature/humidity/pressure printed
  over UART

Both flash via BOOTSEL like any other ticktrace UF2.
