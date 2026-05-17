// bench_minimum (pico-sdk) — equivalent of benchmarks/rp_asm/bench_minimum.S.
//
// Just blink GP25.  Image-size comparison only; no UART, no DWT readout.
// `arm-none-eabi-size build/bench_minimum.elf` after `make` is the
// number we care about.

#include "pico/stdlib.h"

int main(void) {
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
    for (;;) {
        gpio_xor_mask(1u << PICO_DEFAULT_LED_PIN);
        for (volatile int i = 0; i < 250000; i++) { }
    }
}
