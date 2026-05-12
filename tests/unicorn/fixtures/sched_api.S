@ Fixture exposing src/sched.S + src/nvic.S as a callable library for T1.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/sched.S"
    .include "src/nvic.S"

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
    .global _sched_keepalive
_sched_keepalive:
    .word sched_init
    .word task_create
    .word task_post
    .word task_clear
    .word sched_run
    .word critical_enter
    .word critical_exit
    .word nvic_enable_irq
    .word nvic_install_handler
