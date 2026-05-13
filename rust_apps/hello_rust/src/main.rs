// hello_rust — minimum no_std Rust app using the rp-asm core.
//
// Demonstrates:
//   - calling our asm drivers via the rp-asm-sys crate
//   - a Rust `static` in .bss zeroed by _c_runtime_init
//   - DWT cycle timing of a Rust-side workload
//
// Build:
//     make rust-apps          # produces build/hello_rust.uf2

#![no_std]
#![no_main]

use core::panic::PanicInfo;
use core::sync::atomic::{AtomicU32, Ordering};

use rp_asm_sys as sys;

// Rust static in .bss — verifies _c_runtime_init zeroes it.
static TOGGLE_COUNT: AtomicU32 = AtomicU32::new(0);

// rp-asm's startup.S expects to call a symbol named `main`.
#[unsafe(no_mangle)]
pub extern "C" fn main() -> ! {
    unsafe {
        sys::_c_runtime_init();
        sys::xosc_init();
        sys::pll_sys_150_mhz();
        sys::pll_usb_48_mhz();
        sys::clocks_init();
        sys::gpio_led_init();
        sys::uart0_init();
        sys::clocks_post_pll_uart_baud_fixup();
        sys::dwt_init();

        uart0_puts_str("hello from Rust, clk_sys=150 MHz\r\n");

        loop {
            let t0 = sys::dwt_cycles_read();

            sys::gpio_led_toggle();
            let n = TOGGLE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;

            let elapsed = sys::dwt_cycles_since(t0);

            uart0_puts_str("toggle ");
            print_hex8(n);
            uart0_puts_str(" took ");
            print_hex8(elapsed);
            uart0_puts_str(" cycles\r\n");

            // ~250 ms at 150 MHz, 3-cycle inner loop.
            for _ in 0..6_250_000_u32 {
                core::hint::spin_loop();
            }
        }
    }
}

// ----- helpers -------------------------------------------------------------

unsafe fn uart0_puts_str(s: &str) {
    // We can't pass &str directly — our asm expects a null-terminated C string.
    // The cheap trick: write each byte through uart0_putc.  For ~30 chars at
    // a time this is fine; for high-throughput logging, use itm_putc instead.
    for b in s.bytes() {
        unsafe { sys::uart0_putc(b as u32) };
    }
}

fn print_hex8(v: u32) {
    static HEX: &[u8; 16] = b"0123456789abcdef";
    for shift in (0..32).step_by(4).rev() {
        let nib = ((v >> shift) & 0xF) as usize;
        unsafe { sys::uart0_putc(HEX[nib] as u32) };
    }
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    // Simplest possible panic: stop the world.  An LED-blink panic handler
    // is one extra line if you want visual feedback.
    loop {
        core::hint::spin_loop();
    }
}
