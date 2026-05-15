//! bme280_demo — read a Bosch BME280 sensor over I2C, print over UART.
//!
//! Wiring:
//!   SDA = GP4, SCL = GP5, BME280 VCC = 3V3, GND = GND.
//!   I2C address typically 0x76 (or 0x77, depending on SDO pin).
//!
//! Demonstrates pulling a sensor driver crate straight from crates.io
//! and feeding it our asm-backed I2C bus.

#![no_std]
#![no_main]

use bme280_rs::{Bme280, Sample};
use core::fmt::Write;
use embedded_hal::delay::DelayNs;
use rp_asm_hal::{Delay, I2cBus, Uart};
use rp_asm_sys as sys;

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
        sys::gpio_led_init();
        sys::uart0_init();
        sys::clocks_post_pll_uart_baud_fixup();
        sys::dwt_init();
    }

    let mut uart = unsafe { Uart::from_idx(0) };
    let _ = writeln!(uart, "bme280_demo: probing 0x76 on GP4/GP5 @ 100kHz");

    let i2c = I2cBus::new(0, 100_000, 4, 5);
    let delay = Delay::new(150_000_000);

    // Construct the sensor driver.  bme280-rs v0.4 picks the I2C address
    // internally (0x76).
    let mut sensor = Bme280::new(i2c, delay);
    match sensor.init() {
        Ok(()) => { let _ = writeln!(uart, "bme280: init OK"); }
        Err(_) => { let _ = writeln!(uart, "bme280: init FAILED (wiring? address?)"); }
    }

    let mut tick_delay = Delay::new(150_000_000);
    loop {
        match sensor.read_sample() {
            Ok(Sample { temperature, pressure, humidity }) => {
                let t = temperature.unwrap_or(0.0);
                let p = pressure.unwrap_or(0.0);
                let h = humidity.unwrap_or(0.0);
                // Format with a milli-degree precision since libm pulls in
                // a lot of code: just print the integer + 3 decimal digits.
                let t_m = (t * 1000.0) as i32;
                let p_m = (p / 100.0) as i32;            // hPa
                let h_m = (h * 1000.0) as i32;
                let _ = writeln!(uart, "T={}.{:03} C  P={} hPa  H={}.{:03}%",
                    t_m / 1000, (t_m % 1000).unsigned_abs(),
                    p_m,
                    h_m / 1000, (h_m % 1000).unsigned_abs());
            }
            Err(_) => {
                let _ = writeln!(uart, "bme280: read error");
            }
        }
        unsafe { sys::gpio_led_toggle() };
        tick_delay.delay_ns(1_000_000_000); // 1 s
    }
}
