@ =============================================================================
@ bench_spsc.S — measure SPSC byte queue push+pop cycle costs.
@
@ Workload: 10 000 pairs of (push, pop) on a 16-byte queue.  Queue never
@ fills (capacity 15 vs 1 outstanding byte at a time) so we exercise the
@ fast path only.  Report:
@   - cycles_push_x256       average per-push cycles, fixed-point ×256
@   - cycles_pop_x256        average per-pop cycles, fixed-point ×256
@   - cycles_pair            total cycles per push+pop pair
@   - mbps_x100              effective throughput in MB/s ×100 at 150 MHz
@ =============================================================================

    .include "trace.inc"
    .include "spsc.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ ITERS, 10000

    @ A 16-byte queue.
    M_SPSC_BYTE_QUEUE bench_q, 4

    .section .rodata.bench, "a"
name_str:        .asciz "spsc"
metric_push:     .asciz "cycles_push_x256"
metric_pop:      .asciz "cycles_pop_x256"
metric_pair:     .asciz "cycles_pair_avg"
metric_mbps_x100: .asciz "mbps_x100_pair"
banner:          .asciz "bench: spsc push+pop x 10000\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      bench_standard_init

    ldr     r0, =banner
    bl      uart0_puts

    @ Reset queue
    ldr     r0, =bench_q
    bl      spsc_reset

    @ ---- Push-only timing -------------------------------------------------
    @ Push 1 byte, pop 1 byte, repeat.  Time each phase separately by
    @ taking DWT samples at three points: pre-push, post-push/pre-pop,
    @ post-pop — accumulated over ITERS iterations.

    movs    r4, #0                    @ push_sum
    movs    r5, #0                    @ pop_sum
    ldr     r6, =ITERS                @ counter
    movs    r7, #0xA5                 @ test byte

.Lloop:
    bl      dwt_cycles_read
    push    {r0}
    ldr     r0, =bench_q
    mov     r1, r7
    bl      spsc_byte_push
    bl      dwt_cycles_read
    pop     {r1}                      @ t0
    subs    r2, r0, r1                @ push delta
    add     r4, r4, r2

    bl      dwt_cycles_read
    push    {r0}
    ldr     r0, =bench_q
    bl      spsc_byte_pop
    bl      dwt_cycles_read
    pop     {r1}
    subs    r2, r0, r1                @ pop delta
    add     r5, r5, r2

    subs    r6, #1
    bne     .Lloop

    @ ---- Emit ------------------------------------------------------------
    @ cycles_push_x256 = (push_sum << 8) / ITERS
    lsls    r0, r4, #8
    ldr     r1, =ITERS
    udiv    r2, r0, r1
    ldr     r0, =name_str
    ldr     r1, =metric_push
    bl      bench_emit

    lsls    r0, r5, #8
    ldr     r1, =ITERS
    udiv    r2, r0, r1
    ldr     r0, =name_str
    ldr     r1, =metric_pop
    bl      bench_emit

    @ cycles_pair_avg = (push_sum + pop_sum) / ITERS
    add     r0, r4, r5
    ldr     r1, =ITERS
    udiv    r2, r0, r1
    ldr     r0, =name_str
    ldr     r1, =metric_pair
    bl      bench_emit

    @ Throughput: each pair moves 1 byte.  At 150 MHz, MB/s × 100:
    @   bytes_per_sec = 150e6 / cycles_per_pair
    @   MB_per_sec = bytes_per_sec / 1e6
    @   MB_per_sec_x100 = 150e6 * 100 / cycles_per_pair / 1e6
    @                   = 15000 / cycles_per_pair
    @ Use the already-computed cycles_pair_avg in r2.
    ldr     r0, =15000
    udiv    r2, r0, r2
    ldr     r0, =name_str
    ldr     r1, =metric_mbps_x100
    bl      bench_emit

.Lhalt:
    bl      gpio_led_toggle
    ldr     r0, =12500000
1:  subs    r0, #1
    bne     1b
    b       .Lhalt
