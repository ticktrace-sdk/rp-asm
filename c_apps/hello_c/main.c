/* hello_c — minimum C app that uses rp-asm drivers.
 *
 * Demonstrates:
 *   - calling rp-asm clock + UART + GPIO drivers from C
 *   - using a C global (in .bss) that the runtime zeroes for us
 *   - a tight loop that reads DWT cycles and prints them via the
 *     existing UART driver
 *
 * Build:
 *     make c_apps/hello_c.uf2
 */

#include "rp_asm.h"

static uint32_t toggle_count;       /* exercise .bss */
static const char banner[] = "hello from C, clk_sys=150 MHz\r\n";

static void print_hex8(uint32_t v) {
    static const char hex[] = "0123456789abcdef";
    for (int shift = 28; shift >= 0; shift -= 4) {
        uart_putc_blocking(0, hex[(v >> shift) & 0xF]);
    }
}

int main(void) {
    _c_runtime_init();      /* zero .bss before touching toggle_count */

    xosc_init();
    pll_sys_150_mhz();
    pll_usb_48_mhz();
    clocks_init();
    gpio_led_init();
    uart0_init();
    clocks_post_pll_uart_baud_fixup();
    dwt_init();

    uart0_puts(banner);

    for (;;) {
        uint32_t t0 = dwt_cycles_read();

        gpio_led_toggle();
        toggle_count++;

        uint32_t elapsed = dwt_cycles_since(t0);

        uart0_puts("toggle ");
        print_hex8(toggle_count);
        uart0_puts(" took ");
        print_hex8(elapsed);
        uart0_puts(" cycles\r\n");

        for (volatile uint32_t i = 0; i < 6250000; i++) { }
    }
}
