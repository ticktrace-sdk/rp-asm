@ Fixture exposing src/adc.S + src/trng.S as a callable library for T1.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/adc.S"
    .include "src/trng.S"

    .section .vectors, "ax"
    .align 2
    .global _vectors
_vectors:
    .word _stack_top
    .word _start + 1

    .section .text._start, "ax"
    .thumb_func
    .global _start
_start:
    .global _park
_park:
.Lpark:
    b       .Lpark

    .section .rodata._keepalive, "a"
    .align 2
    .global _adc_trng_keepalive
_adc_trng_keepalive:
    .word adc_init
    .word adc_select_input
    .word adc_set_temp_sensor_enabled
    .word adc_set_round_robin
    .word adc_set_clkdiv
    .word adc_read
    .word adc_run
    .word adc_fifo_setup
    .word adc_fifo_get_blocking
    .word adc_fifo_drain
    .word trng_init
    .word trng_get_random_word
    .word trng_get_random_block
