// bench_irq_latency (pico-sdk) — paired with rp-asm/bench_irq_latency.S.
//
// Arm TIMER0 ALARM0 for "now + 1 ms"; ISR records DWT cycle delta.
// Repeat 32×, report min/max/avg of the IRQ-entry latency portion
// (raw delta minus the expected 1000 µs × 150 cycles/µs offset).

#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/timer.h"
#include "hardware/irq.h"
#include "hardware/structs/dwt.h"
#include "hardware/structs/timer.h"
#include "hardware/clocks.h"

#define N_SAMPLES        32u
#define ALARM_DELAY_US   1000u
#define EXPECTED_BASE    150000u   // 1000 µs * 150 cycles/µs

static volatile uint32_t arm_cycle, isr_cycle;
static uint32_t samples[N_SAMPLES];
static volatile uint32_t sample_idx;

static void dwt_init_local(void) {
    *((volatile uint32_t*)0xE000EDFC) |= (1u << 24);
    *((volatile uint32_t*)0xE0001FB0)  = 0xC5ACCE55;
    dwt_hw->cyccnt = 0;
    dwt_hw->ctrl  |= 1;
}

static void __not_in_flash_func(alarm_isr)(void) {
    uint32_t now = dwt_hw->cyccnt;
    samples[sample_idx++] = (now - arm_cycle) - EXPECTED_BASE;
    hw_clear_bits(&timer_hw->intr, 1u << 0);
    isr_cycle = 1;
}

int main(void) {
    set_sys_clock_khz(150000, true);
    stdio_uart_init_full(uart0, 115200, 0, 1);
    dwt_init_local();

    printf("bench: TIMER0 ALARM0 IRQ latency, 32 samples\r\n");

    irq_set_exclusive_handler(TIMER_IRQ_0, alarm_isr);
    irq_set_enabled(TIMER_IRQ_0, true);
    hw_set_bits(&timer_hw->inte, 1u << 0);

    for (uint32_t i = 0; i < N_SAMPLES; i++) {
        uint32_t target = timer_hw->timerawl + ALARM_DELAY_US;
        arm_cycle = dwt_hw->cyccnt;
        timer_hw->alarm[0] = target;
        while (isr_cycle == 0) { /* spin */ }
        isr_cycle = 0;
    }

    uint32_t min = ~0u, max = 0, sum = 0;
    for (uint32_t i = 0; i < N_SAMPLES; i++) {
        uint32_t s = samples[i];
        if (s < min) min = s;
        if (s > max) max = s;
        sum += s;
    }
    uint32_t avg = sum / N_SAMPLES;

    printf("BENCH name=irq_latency metric=min_cycles value=0x%08lx\r\n", (unsigned long)min);
    printf("BENCH name=irq_latency metric=max_cycles value=0x%08lx\r\n", (unsigned long)max);
    printf("BENCH name=irq_latency metric=avg_cycles value=0x%08lx\r\n", (unsigned long)avg);

    for (;;) tight_loop_contents();
}
