// bench_gpio_toggle (pico-sdk) — paired with rp-asm/bench_gpio_toggle.S.
//
// 100_000 calls of gpio_xor_mask, timed with DWT.CYCCNT.  Prints the
// same "BENCH …" line format the rp-asm side emits.

#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/structs/dwt.h"

#define LED_PIN 25
#define ITERS   100000u

static void dwt_init_local(void) {
    *((volatile uint32_t*)0xE000EDFC) |= (1u << 24);  // DEMCR.TRCENA
    *((volatile uint32_t*)0xE0001FB0)  = 0xC5ACCE55;  // DWT_LAR (unlock)
    dwt_hw->cyccnt = 0;
    dwt_hw->ctrl  |= 1;                                // CYCCNTENA
}

int main(void) {
    set_sys_clock_khz(150000, true);
    stdio_uart_init_full(uart0, 115200, 0, 1);
    gpio_init(LED_PIN);
    gpio_set_dir(LED_PIN, GPIO_OUT);
    dwt_init_local();

    printf("bench: gpio_toggle x %u\r\n", (unsigned)ITERS);

    uint32_t t0 = dwt_hw->cyccnt;
    for (uint32_t i = 0; i < ITERS; i++) {
        gpio_xor_mask(1u << LED_PIN);
    }
    uint32_t cycles = dwt_hw->cyccnt - t0;

    printf("BENCH name=gpio_toggle metric=cycles_total value=0x%08lx\r\n",
           (unsigned long)cycles);
    printf("BENCH name=gpio_toggle metric=cycles_per_iter_x256 value=0x%08lx\r\n",
           (unsigned long)((((uint64_t)cycles) << 8) / ITERS));

    for (;;) tight_loop_contents();
}
