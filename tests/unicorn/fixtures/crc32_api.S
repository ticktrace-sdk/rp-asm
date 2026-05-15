@ Fixture exposing src/crc32.S as a callable library for the T1 harness.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/crc32.S"

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
    .global _crc32_keepalive
_crc32_keepalive:
    .word crc32_compute
