@ Fixture exposing src/sched.S + src/sched_stats.S + src/nvic.S for T1.

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/sched.S"
    .include "src/sched_stats.S"
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

    @ A "user task" we can install via task_create_traced and then
    @ invoke directly (by branching to the trampoline) to verify the
    @ stats fields update.  Reads DWT (mocked by the test) twice via
    @ the trampoline; the body itself does fixed work so cycles_total
    @ is predictable.
    .section .text.fake_user_fn, "ax"
    .thumb_func
    .global fake_user_fn
fake_user_fn:
    nop                                  @ minimum non-empty body
    nop
    bx      lr

    .section .rodata._keepalive, "a"
    .align 2
    .global _stats_keepalive
_stats_keepalive:
    .word task_create_traced
    .word task_stats_total
    .word task_stats_invocations
    .word task_stats_max
    .word task_stats_reset
    .word task_stats_reset_all
    .word task_stats
    .word fake_user_fn
    .word _task_tramp_0
    .word _task_tramp_3
