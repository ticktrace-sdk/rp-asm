// rp-asm-sys: raw extern "C" declarations for every public function in
// the ticktrace driver core.  Calls into these are `unsafe` from Rust;
// build a safe wrapper crate on top if you want typed pins, RAII, etc.
//
// The actual symbols live in librp_asm.a, built by the top-level Makefile
// (`make build/librp_asm.a`).  Apps link against it via their own build.rs
// emitting `cargo:rustc-link-lib=static=rp_asm`.

#![no_std]
#![allow(non_snake_case)]
#![allow(non_camel_case_types)]
#![allow(clippy::missing_safety_doc)]

pub type task_fn_t = unsafe extern "C" fn();

unsafe extern "C" {
    // Clocks
    pub fn xosc_init();
    pub fn pll_sys_150_mhz();
    pub fn pll_usb_48_mhz();
    pub fn clocks_init();
    pub fn clocks_post_pll_uart_baud_fixup();
    pub fn tick_init();

    // Watchdog
    pub fn watchdog_disable();
    pub fn watchdog_enable(timeout_us: u32);
    pub fn watchdog_feed();

    // GPIO
    pub fn gpio_init(pin: u32);
    pub fn gpio_set_function(pin: u32, func: u32);
    pub fn gpio_set_dir(pin: u32, out: u32);
    pub fn gpio_put(pin: u32, value: u32);
    pub fn gpio_get(pin: u32) -> u32;
    pub fn gpio_toggle(pin: u32);
    pub fn gpio_pull_up(pin: u32);
    pub fn gpio_pull_down(pin: u32);
    pub fn gpio_led_init();
    pub fn gpio_led_toggle();

    // UART
    pub fn uart_init(idx: u32, baud: u32, clk_peri_hz: u32);
    pub fn uart_set_baudrate(idx: u32, baud: u32, clk_peri_hz: u32);
    pub fn uart_putc_blocking(idx: u32, byte: u32);
    pub fn uart_puts_blocking(idx: u32, s: *const u8);
    pub fn uart_getc_blocking(idx: u32) -> u32;
    pub fn uart0_init();
    pub fn uart0_putc(byte: u32);
    pub fn uart0_puts(s: *const u8);

    // DMA / Timer / SysTick / NVIC
    pub fn dma_init();
    pub fn time_us_32() -> u32;
    pub fn alarm_set(timer: u32, alarm: u32, lo: u32, hi: u32);
    pub fn alarm_clear_irq(timer: u32, alarm: u32);
    pub fn nvic_enable_irq(irq: u32);
    pub fn nvic_install_handler(irq: u32, handler: task_fn_t);

    // SHA256
    pub fn sha256_init();
    pub fn sha256_compute(msg: *const u8, len: u32, digest: *mut u8);

    // ADC + TRNG
    pub fn adc_init();
    pub fn adc_select_input(channel: u32);
    pub fn adc_set_temp_sensor_enabled(on: u32);
    pub fn adc_read() -> u32;
    pub fn trng_init();
    pub fn trng_get_random_word() -> u32;

    // Trace (DWT / ITM)
    pub fn dwt_init();
    pub fn dwt_cycles_read() -> u32;
    pub fn dwt_cycles_reset();
    pub fn dwt_cycles_since(start: u32) -> u32;
    pub fn trace_init(clk_sys_hz: u32, swo_baud: u32);
    pub fn itm_putc(port: u32, byte: u32);
    pub fn itm_puts(port: u32, s: *const u8);

    // Scheduler
    pub fn sched_init();
    pub fn task_create(id: u32, fn_: task_fn_t, prio: u32);
    pub fn task_create_traced(id: u32, fn_: task_fn_t, prio: u32);
    pub fn task_post(id: u32);
    pub fn task_post_n(mask: u32);
    pub fn task_clear(id: u32);
    pub fn sched_run() -> !;
    pub fn critical_enter() -> u32;
    pub fn critical_exit(saved: u32);
    pub fn critical_enter_basepri(prio: u32) -> u32;
    pub fn critical_exit_basepri(saved: u32);
    pub fn task_stats_total(id: u32) -> u32;
    pub fn task_stats_invocations(id: u32) -> u32;
    pub fn task_stats_max(id: u32) -> u32;

    // C-runtime helper (we use this from Rust too, to zero .bss for Rust
    // statics that aren't explicitly initialised).
    pub fn _c_runtime_init();
}
