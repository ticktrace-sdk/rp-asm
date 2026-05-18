@ =============================================================================
@ bench_minimum.S: smallest blinker that still uses the SDK's boot path.
@
@ Measurement: `arm-none-eabi-size build/bench_minimum.elf`; compare the
@ .text + .rodata total to the pico-sdk equivalent (benchmarks/pico_sdk/
@ bench_minimum).
@
@ No UART, no clock setup beyond the default bootrom hand-off (XOSC 12 MHz).
@ Just blink GP25 in a CPU-cycle busy loop. The point of this bench is
@ purely to measure how small "minimum viable" can get; runtime cycle
@ counts aren't interesting here (the loop is calibrated to look like
@ blinking, not to match wall-clock).
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      gpio_led_init
1:  bl      gpio_led_toggle
    ldr     r0, =250000        @ ~60 ms @ 12 MHz (3-cycle inner)
2:  subs    r0, #1
    bne     2b
    b       1b
