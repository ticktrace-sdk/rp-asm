# Rust bridge

Opt-in Rust toolchain on top of the ticktrace core. Write `#![no_std]`
Rust applications that call our asm drivers via `extern "C"`. AAPCS
makes the bridge free; the work is wiring cargo to find our static
archive and use our linker script.

> **Branch note:** lives on `claude/c-rust-bridge`. The asm-only
> mainline never references Rust code; the bridge is strictly additive.

## What ships

| File | Purpose |
| ---- | ------- |
| `rust_bridge/rp-asm-sys/`     | `extern "C"` declarations for every public driver |
| `rust_apps/hello_rust/`       | Example: blink + UART log with DWT timing |
| Makefile `build/librp_asm.a`  | Bundles every driver `.o` into a static archive |
| Makefile `rust-apps` target   | Runs `cargo build --release` per app, UF2-packs the output |

## Build

```
rustup target add thumbv8m.main-none-eabi
make rust-apps                # builds build/<name>.uf2 for every rust_apps/<name>/
```

Cargo's release profile is configured for size:

```toml
[profile.release]
opt-level = "s"      # optimise for size, matches our 'every cycle matters' image
lto = true
codegen-units = 1
panic = "abort"
strip = true
```

## Hello world

```rust
#![no_std]
#![no_main]

use core::sync::atomic::{AtomicU32, Ordering};
use rp_asm_sys as sys;

static COUNT: AtomicU32 = AtomicU32::new(0);

#[unsafe(no_mangle)]
pub extern "C" fn main() -> ! {
    unsafe {
        sys::_c_runtime_init();          // zero .bss for `COUNT`
        sys::xosc_init();
        sys::pll_sys_150_mhz();
        sys::pll_usb_48_mhz();
        sys::clocks_init();
        sys::gpio_led_init();
        sys::uart0_init();
        sys::clocks_post_pll_uart_baud_fixup();
        sys::dwt_init();

        loop {
            sys::gpio_led_toggle();
            COUNT.fetch_add(1, Ordering::Relaxed);
            for _ in 0..6_250_000_u32 {
                core::hint::spin_loop();
            }
        }
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop { core::hint::spin_loop() } }
```

`hello_rust` builds to **1040 bytes** of `.text`, within rounding of the
C equivalent (1004 B). All cycle costs of the drivers themselves are
unchanged because they're the same asm functions.

## How the build hangs together

1. `make build/librp_asm.a` runs `arm-none-eabi-ar` over every driver
   `.o` (the same objects that build `build/blinky.elf`) plus the
   `c_bridge/*.o` runtime helpers.
2. Cargo's `build.rs` (in each `rust_apps/<name>/`) emits:
   - `cargo:rustc-link-search=native=<repo>/build`
   - `cargo:rustc-link-lib=static=rp_asm`
   - `cargo:rustc-link-arg=-T<repo>/link/sram.ld`
3. The Rust linker driver (`arm-none-eabi-ld` per `.cargo/config.toml`)
   pulls in `librp_asm.a`, resolves Rust's calls to `xosc_init`,
   `gpio_put`, etc., and emits a single ELF.
4. Makefile copies that ELF into `build/<name>.elf`, objcopies to
   `.bin`, UF2-packs.

You can also drive cargo by hand:
```sh
cd rust_apps/hello_rust
cargo build --release
arm-none-eabi-size target/thumbv8m.main-none-eabi/release/hello_rust
```

## Calling driver functions

Every public function from the ticktrace core appears as an `unsafe extern
"C"` import in `rp_asm_sys::*`:

```rust
unsafe {
    sys::gpio_put(25, 1);
    sys::uart_putc_blocking(0, b'A' as u32);
    let cycles = sys::dwt_cycles_since(start);
}
```

The `unsafe` is intentional: Rust can't know that you're calling these
in the right order, with valid pin numbers, etc. A natural follow-on
project would be a `ticktrace` (no `-sys`) crate with safe wrappers: typed
pin enums, RAII for peripheral handles, `Result` returns where errors
are possible.

## Why not just use `rp-hal`?

Embedded Rust has [rp-hal](https://github.com/rp-rs/rp-hal), the
community Rust HAL for RP2350. It's mature, idiomatic, and 100% Rust.

| Reason to use `ticktrace` from Rust | Reason to use `rp-hal` |
| -------------------------------- | ---------------------- |
| Smaller image (~1 KB vs ~5-10 KB for an rp-hal "hello blinky") | Idiomatic Rust types throughout |
| Faster boot, smaller `.text` for the driver layer | Mature ecosystem integration (embedded-hal traits) |
| Per-driver cycle counts you can quote | Builds straight from `cargo new` with no Makefile |
| Asm drivers are reusable from C / other-FFI | Stays purely in Cargo for releases |

If your application logic is heavy and your driver-level cycle count
doesn't matter much, rp-hal is the more comfortable choice. If you're
the kind of developer who clicked on a project called "ticktrace" in the
first place, you probably want this bridge.

## Linker integration

Cargo emits an ELF that uses our `link/sram.ld`. The same script that
powers `build/blinky.uf2` powers `build/hello_rust.uf2`. This means:

- Vector table sits at `0x20000000` (top of SRAM)
- `IMAGE_DEF` block at offset `0x40` (bootrom requirement)
- Stack at top of SRAM (`_stack_top = 0x2007FFFC`)
- Rust statics in `.bss` are zeroed by `_c_runtime_init()` you must call
  from `main()`

Rust's `cortex-m-rt` crate provides its own startup; we deliberately
*don't* use it because `src/startup.S` already does this work and is
cycle-tuned. The trade-off: you can't use `#[entry]` from `cortex-m-rt`;
you write `#[unsafe(no_mangle)] pub extern "C" fn main() -> !`.

## Panic handlers

A `no_std` Rust binary needs a `#[panic_handler]`. The hello_rust app
uses an infinite `spin_loop`; production code might:

- LED-blink at 8 Hz to signal panic visually
- Send the panic message over UART before halting
- Trigger a watchdog reset on purpose

```rust
#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    unsafe {
        sys::uart0_puts(b"PANIC\r\n\0".as_ptr());
        loop { sys::gpio_led_toggle(); for _ in 0..1_000_000_u32 { core::hint::spin_loop() } }
    }
}
```

## What's missing

- **No safe wrapper crate yet** (`ticktrace` crate, sans `-sys`). Worth
  building if you start using this for non-trivial apps.
- **No `embedded-hal` impls.** Not a priority because the apps targeting
  this bridge presumably want the asm directly, not abstraction.
- **No `defmt` integration.** Could be added by sending defmt frames
  over ITM (we have `itm_putw` already).
- **Atomic operations.** `AtomicU32` works because Cortex-M33 has
  LDREX/STREX. Test before relying on `compare_exchange_weak` in
  contention-heavy code.

## Limitations

- Single-core only (M6 / dual-core scheduler hasn't shipped to mainline).
- `std::format!` and friends won't link; `no_std` only.
- `println!` is unavailable; use the asm `uart0_puts` / `itm_puts` directly
  or write a tiny `core::fmt::Write` implementation.

## Picking Rust vs C vs asm

| Layer | Best language | Why |
| ----- | ------------- | --- |
| Driver / ISR top-half / cycle-critical | **asm** | Cycle counts you can quote |
| Application logic, protocol parsing, state machines | **Rust** | Type safety + ecosystem |
| Quick port from existing C libs (TinyUSB, FatFs, mbedTLS) | **C** | Bridge already exists |

The three layers compose: a Rust application can pull in a C library
(via `bindgen` + the existing C bridge) which calls the asm core. All
through plain AAPCS function calls.
