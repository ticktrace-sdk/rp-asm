@ Fixture exposing src/spsc.S as a callable library, plus a queue.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/spsc.S"

    @ A 16-byte (4-bit-mask = log2=4) test queue.
    M_SPSC_BYTE_QUEUE  test_q, 4

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
    .global _spsc_keepalive
_spsc_keepalive:
    .word spsc_byte_push
    .word spsc_byte_pop
    .word spsc_byte_count
    .word spsc_reset
    .word test_q
