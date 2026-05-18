//! ssd1306_demo: drive a 128×64 SSD1306 OLED over I2C0.
//!
//! Wiring:
//!   SDA = GP4, SCL = GP5, OLED VCC = 3V3, GND = GND.
//!   The display's I2C address is 0x3C (most boards).
//!
//! This app pulls the `ssd1306` and `embedded-graphics` crates from
//! crates.io; neither of them knows about ticktrace.  They talk to the
//! I2C bus through the `embedded_hal::i2c::I2c` trait we implement in
//! `rp-asm-hal`.  Same crate, same source, same Cargo.toml lines as
//! anyone else's embedded Rust project, except the underlying
//! driver is asm.

#![no_std]
#![no_main]

use embedded_graphics::mono_font::{ascii::FONT_6X10, MonoTextStyle};
use embedded_graphics::pixelcolor::BinaryColor;
use embedded_graphics::prelude::*;
use embedded_graphics::text::Text;
use embedded_hal::delay::DelayNs;
use rp_asm_hal::{Delay, I2cBus};
use rp_asm_sys as sys;
use ssd1306::{prelude::*, I2CDisplayInterface, Ssd1306};

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    rp_asm_rt::panic_blink();
}

rp_asm_rt::entry!(app_main);

fn app_main() -> ! {
    unsafe {
        sys::xosc_init();
        sys::pll_sys_150_mhz();
        sys::pll_usb_48_mhz();
        sys::clocks_init();
        sys::clocks_post_pll_uart_baud_fixup();
        sys::gpio_led_init();
        sys::dwt_init();
    }

    // I2C0 @ 400 kHz on GP4 (SDA) / GP5 (SCL).
    let i2c = I2cBus::new(0, 400_000, 4, 5);

    let interface = I2CDisplayInterface::new(i2c);
    let mut display = Ssd1306::new(
        interface,
        DisplaySize128x64,
        DisplayRotation::Rotate0,
    )
    .into_buffered_graphics_mode();
    let _ = display.init();
    let _ = display.clear(BinaryColor::Off);

    let style = MonoTextStyle::new(&FONT_6X10, BinaryColor::On);
    let _ = Text::new("ticktrace + embedded-hal", Point::new(2, 12), style).draw(&mut display);
    let _ = Text::new("ssd1306 from crates.io", Point::new(2, 28), style).draw(&mut display);
    let _ = Text::new("asm drivers underneath", Point::new(2, 44), style).draw(&mut display);
    let _ = display.flush();

    let mut delay = Delay::new(150_000_000);

    let mut counter: u32 = 0;
    loop {
        unsafe { sys::gpio_led_toggle() };
        counter = counter.wrapping_add(1);
        delay.delay_ns(250_000_000); // 250 ms

        // Refresh the screen with a counter so we can see liveness.
        let _ = display.clear(BinaryColor::Off);
        let _ = Text::new("ticktrace + embedded-hal", Point::new(2, 12), style).draw(&mut display);
        let _ = Text::new("ssd1306 from crates.io", Point::new(2, 28), style).draw(&mut display);

        let mut buf = [0u8; 16];
        let s = format_u32(&mut buf, counter);
        let _ = Text::new(s, Point::new(2, 44), style).draw(&mut display);

        let _ = display.flush();
    }
}

/// Tiny decimal formatter to avoid pulling in `core::fmt` machinery.
/// Writes into `buf` and returns the &str view.
fn format_u32<'a>(buf: &'a mut [u8], mut v: u32) -> &'a str {
    let mut tmp = [0u8; 10];
    let mut idx = tmp.len();
    if v == 0 {
        idx -= 1;
        tmp[idx] = b'0';
    } else {
        while v > 0 {
            idx -= 1;
            tmp[idx] = b'0' + (v % 10) as u8;
            v /= 10;
        }
    }
    let n = tmp.len() - idx;
    buf[..n].copy_from_slice(&tmp[idx..]);
    core::str::from_utf8(&buf[..n]).unwrap()
}
