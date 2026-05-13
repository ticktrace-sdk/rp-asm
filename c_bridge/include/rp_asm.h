/* =============================================================================
 * rp_asm.h - C declarations for every public rp-asm driver function.
 *
 * One-stop header for C apps that want to use the rp-asm core.  Every
 * function listed here is defined in the corresponding asm source file
 * (under src/) and follows AAPCS, so C call-sites work directly.
 *
 * Include this once from your C app:
 *     #include "rp_asm.h"
 *
 * Link against the rp-asm static archive (see c_bridge/Makefile.frag).
 * ============================================================================= */

#ifndef RP_ASM_H
#define RP_ASM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ----- Clocks (src/clocks.S, src/xosc.S, src/pll.S, src/tick.S) ---------- */
void xosc_init(void);
void pll_sys_150_mhz(void);
void pll_usb_48_mhz(void);
void clocks_init(void);
void clocks_post_pll_uart_baud_fixup(void);
void tick_init(void);

/* ----- Watchdog (src/watchdog.S) ----------------------------------------- */
void watchdog_disable(void);
void watchdog_enable(uint32_t timeout_us);
void watchdog_feed(void);

/* ----- GPIO (src/gpio.S) ------------------------------------------------- */
void     gpio_init(uint32_t pin);
void     gpio_set_function(uint32_t pin, uint32_t func);
void     gpio_set_dir(uint32_t pin, uint32_t out);
void     gpio_put(uint32_t pin, uint32_t value);
uint32_t gpio_get(uint32_t pin);
void     gpio_toggle(uint32_t pin);
void     gpio_pull_up(uint32_t pin);
void     gpio_pull_down(uint32_t pin);
void     gpio_set_input_enabled(uint32_t pin, uint32_t enable);
void     gpio_set_drive_strength(uint32_t pin, uint32_t drive);
void     gpio_led_init(void);
void     gpio_led_toggle(void);

/* ----- UART (src/uart.S) ------------------------------------------------- */
void     uart_init(uint32_t idx, uint32_t baud, uint32_t clk_peri_hz);
void     uart_deinit(uint32_t idx);
void     uart_set_baudrate(uint32_t idx, uint32_t baud, uint32_t clk_peri_hz);
void     uart_set_format(uint32_t idx, uint32_t data_bits,
                         uint32_t stop_bits, uint32_t parity);
void     uart_set_hw_flow(uint32_t idx, uint32_t cts, uint32_t rts);
void     uart_set_irqs_enabled(uint32_t idx, uint32_t mask);
void     uart_acknowledge_irq(uint32_t idx, uint32_t mask);
void     uart_set_dma_enabled(uint32_t idx, uint32_t tx, uint32_t rx);
uint32_t uart_is_writable(uint32_t idx);
uint32_t uart_is_readable(uint32_t idx);
void     uart_putc_blocking(uint32_t idx, uint32_t byte);
void     uart_puts_blocking(uint32_t idx, const char *s);
uint32_t uart_getc_blocking(uint32_t idx);
void     uart0_init(void);
void     uart0_putc(uint32_t byte);
void     uart0_puts(const char *s);

/* ----- I2C (src/i2c.S) --------------------------------------------------- */
void     i2c_init(uint32_t idx, uint32_t hz);
int32_t  i2c_write_blocking(uint32_t idx, uint32_t addr,
                            const uint8_t *src, uint32_t len, uint32_t nostop);
int32_t  i2c_read_blocking(uint32_t idx, uint32_t addr,
                           uint8_t *dst, uint32_t len, uint32_t nostop);
void     i2c_set_pins(uint32_t idx, uint32_t sda_pin, uint32_t scl_pin);

/* ----- SPI (src/spi.S) --------------------------------------------------- */
void     spi_init(uint32_t idx, uint32_t baud_hz);
void     spi_set_format(uint32_t idx, uint32_t data_bits,
                        uint32_t cpol, uint32_t cpha, uint32_t frame);
void     spi_set_pins(uint32_t idx, uint32_t sck, uint32_t mosi,
                      uint32_t miso, uint32_t cs);
void     spi_write_blocking(uint32_t idx, const uint8_t *src, uint32_t n);
void     spi_read_blocking(uint32_t idx, uint8_t tx,
                           uint8_t *dst, uint32_t n);
void     spi_write_read_blocking(uint32_t idx, const uint8_t *src,
                                 uint8_t *dst, uint32_t n);

/* ----- DMA (src/dma.S) --------------------------------------------------- */
void     dma_init(void);
void     dma_channel_configure(uint32_t ch, uint32_t ctrl,
                               const void *read, void *write,
                               uint32_t count, uint32_t trigger);
void     dma_channel_wait_for_finish(uint32_t ch);

/* ----- TIMER0 / SysTick / NVIC (src/timer.S, src/systick.S, src/nvic.S) -- */
uint32_t time_us_32(void);
void     delay_us(uint32_t us);
void     delay_ms(uint32_t ms);
void     alarm_set(uint32_t timer, uint32_t alarm, uint32_t lo, uint32_t hi);
void     alarm_clear_irq(uint32_t timer, uint32_t alarm);
void     systick_start_periodic(uint32_t period);
void     systick_stop(void);
void     nvic_enable_irq(uint32_t irq);
void     nvic_install_handler(uint32_t irq, void (*handler)(void));

/* ----- SHA256 (src/sha256.S) --------------------------------------------- */
void     sha256_init(void);
void     sha256_compute(const uint8_t *msg, uint32_t len, uint8_t *digest);

/* ----- ADC + TRNG (src/adc.S, src/trng.S) -------------------------------- */
void     adc_init(void);
void     adc_select_input(uint32_t channel);
void     adc_set_temp_sensor_enabled(uint32_t on);
uint32_t adc_read(void);
void     trng_init(void);
uint32_t trng_get_random_word(void);
void     trng_get_random_block(uint32_t *dst, uint32_t words);

/* ----- DWT / ITM (src/trace.S) ------------------------------------------- */
void     dwt_init(void);
uint32_t dwt_cycles_read(void);
void     dwt_cycles_reset(void);
uint32_t dwt_cycles_since(uint32_t start);
void     trace_init(uint32_t clk_sys_hz, uint32_t swo_baud);
void     itm_init(void);
void     itm_putc(uint32_t port, uint32_t byte);
void     itm_puts(uint32_t port, const char *s);
void     itm_putw(uint32_t port, uint32_t word);

/* ----- Scheduler (src/sched.S, src/sched_stats.S) ------------------------ */
typedef void (*task_fn_t)(void);
void     sched_init(void);
void     task_create(uint32_t id, task_fn_t fn, uint32_t prio);
void     task_create_traced(uint32_t id, task_fn_t fn, uint32_t prio);
void     task_post(uint32_t id);
void     task_post_n(uint32_t mask);
void     task_clear(uint32_t id);
void     sched_run(void) __attribute__((noreturn));
uint32_t critical_enter(void);
void     critical_exit(uint32_t saved);
uint32_t critical_enter_basepri(uint32_t prio);
void     critical_exit_basepri(uint32_t saved);
uint32_t task_stats_total(uint32_t id);
uint32_t task_stats_invocations(uint32_t id);
uint32_t task_stats_max(uint32_t id);
void     task_stats_reset(uint32_t id);
void     task_stats_reset_all(void);

/* ----- SPSC byte queue (src/spsc.S) -------------------------------------- *
 * Layout: each queue is { head, tail, mask, _pad, data[size] }.  Use the
 * M_SPSC_BYTE_QUEUE asm macro to declare one.  From C, you receive a
 * pointer to that struct.
 */
typedef struct rp_spsc_byte_queue rp_spsc_byte_queue;
int32_t  spsc_byte_push(rp_spsc_byte_queue *q, uint32_t byte);
int32_t  spsc_byte_pop(rp_spsc_byte_queue *q);
uint32_t spsc_byte_count(rp_spsc_byte_queue *q);
void     spsc_reset(rp_spsc_byte_queue *q);

/* ----- C-runtime helper (c_bridge/runtime.S) ----------------------------- *
 * Call once from main() before touching any C global / static. */
void     _c_runtime_init(void);

#ifdef __cplusplus
}
#endif

#endif /* RP_ASM_H */
