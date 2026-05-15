//! rp-asm-rt — runtime helpers for rp-asm Rust apps.
//!
//! Provides:
//! - A `#[global_allocator]` implementation (bump allocator) so crates
//!   that need `alloc` link.  Carve out 32 KiB of SRAM, never free.
//! - The `entry!()` macro that wraps a user `fn() -> !` as `extern "C" fn main`
//!   and runs `_c_runtime_init` first.
//! - A default `#[panic_handler]` that the user app can opt into.
//!
//! Each helper is opt-in.  If you don't enable the `alloc-bump` feature
//! you don't get the allocator (and don't pay the 32 KiB reservation).

#![no_std]

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::sync::atomic::{AtomicUsize, Ordering};

pub use rp_asm_sys as sys;

// ============================================================================
// Bump allocator
// ============================================================================
//
// Reservation lives in a `static` (.bss).  At first allocation, the bump
// pointer starts at the buffer base; each request increments it past the
// allocation, returning the base.  Frees are no-ops.
//
// Pattern fits embedded usage: allocate during startup, run forever.
// Crates that allocate-then-free repeatedly will leak; if you need true
// reclamation, swap this for `linked_list_allocator` (vendored from crates.io).

const HEAP_SIZE: usize = 32 * 1024;

#[repr(C, align(8))]
struct Heap(UnsafeCell<[u8; HEAP_SIZE]>);

unsafe impl Sync for Heap {}

static HEAP: Heap = Heap(UnsafeCell::new([0; HEAP_SIZE]));
static HEAP_NEXT: AtomicUsize = AtomicUsize::new(0);

pub struct BumpAllocator;

unsafe impl GlobalAlloc for BumpAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let align = layout.align();
        let size = layout.size();

        // Repeatedly try to bump the next pointer in CAS-style.  Cortex-M33
        // has a single thread of execution + (possibly) interrupts; relaxed
        // ordering suffices for the bump pointer because we own the
        // [base..end) region linearly.
        let mut current = HEAP_NEXT.load(Ordering::Relaxed);
        loop {
            // Align up
            let aligned = (current + align - 1) & !(align - 1);
            let next = match aligned.checked_add(size) {
                Some(n) if n <= HEAP_SIZE => n,
                _ => return core::ptr::null_mut(),
            };
            match HEAP_NEXT.compare_exchange_weak(
                current,
                next,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => {
                    let base = unsafe { (*HEAP.0.get()).as_mut_ptr() };
                    return unsafe { base.add(aligned) };
                }
                Err(now) => current = now,
            }
        }
    }

    unsafe fn dealloc(&self, _: *mut u8, _: Layout) {
        // bump allocator: free is a no-op.
    }
}

/// Bytes currently allocated. Useful for telemetry / a UART command
/// that prints "heap used: X / 32768".
pub fn heap_used() -> usize {
    HEAP_NEXT.load(Ordering::Relaxed)
}

pub fn heap_capacity() -> usize {
    HEAP_SIZE
}

// ============================================================================
// Entry macro
// ============================================================================
//
// Wraps a user `fn() -> !` (signature must be `pub fn <name>() -> !`) as the
// `main` symbol rp-asm's startup.S calls.  Runs _c_runtime_init first so
// .bss is zeroed before any Rust static is read.
//
// Usage:
//     rp_asm_rt::entry!(app_main);
//     fn app_main() -> ! { loop {} }

#[macro_export]
macro_rules! entry {
    ($f:ident) => {
        #[unsafe(no_mangle)]
        pub extern "C" fn main() -> ! {
            unsafe {
                $crate::sys::_c_runtime_init();
            }
            $f()
        }
    };
}

// ============================================================================
// Default panic handler
// ============================================================================
//
// Opt-in: add `panic-halt` or your own #[panic_handler] in the app crate.
// We don't define one here because the panic handler is a singleton — if
// rp-asm-rt provided one, every app would have to opt out.  Instead we
// expose a function the user's panic handler can call.

/// Halt the CPU with the LED blinking at 8 Hz to signal panic.
///
/// Call this from your app's `#[panic_handler]`.  Never returns.
pub fn panic_blink() -> ! {
    unsafe {
        // Init LED in case it wasn't already
        sys::gpio_led_init();
        loop {
            sys::gpio_led_toggle();
            // ~60 ms at 150 MHz
            for _ in 0..3_000_000_u32 {
                core::hint::spin_loop();
            }
        }
    }
}
