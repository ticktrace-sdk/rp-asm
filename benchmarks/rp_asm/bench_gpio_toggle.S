@ =============================================================================
@ bench_gpio_toggle.S — N× gpio_toggle(25), report DWT cycles.
@
@ Workload: 100_000 calls of `gpio_toggle(25)` in a straight `bl`/`subs`/`bne`
@ loop.  Reports total cycles and cycles-per-call.
@
@ Expected on rp-asm: gpio_toggle is 4 cycles (mask + cmp + str + bx) plus
@ ~4 cycles loop overhead (bl + subs + bne taken) = ~8 cycles per iter.
@ Total ~800_000 cycles ≈ 5.3 ms at 150 MHz.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ ITERS, 100000

    .section .rodata.bench, "a"
name_str:    .asciz "gpio_toggle"
metric_total: .asciz "cycles_total"
metric_per:   .asciz "cycles_per_iter_x256"
banner:       .asciz "bench: gpio_toggle x 100000\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      bench_standard_init

    ldr     r0, =banner
    bl      uart0_puts

    bl      dwt_cycles_reset
    bl      dwt_cycles_read
    mov     r4, r0                  @ t0

    ldr     r5, =ITERS
1:  movs    r0, #25
    bl      gpio_toggle
    subs    r5, #1
    bne     1b

    mov     r0, r4
    bl      dwt_cycles_since
    mov     r6, r0                  @ total cycles

    @ Emit "BENCH name=gpio_toggle metric=cycles_total value=…"
    ldr     r0, =name_str
    ldr     r1, =metric_total
    mov     r2, r6
    bl      bench_emit

    @ Cycles per iter * 256 (fixed-point so we don't lose the fractional bits)
    @ value = (total << 8) / ITERS
    lsls    r0, r6, #8
    ldr     r1, =ITERS
    udiv    r2, r0, r1
    ldr     r0, =name_str
    ldr     r1, =metric_per
    bl      bench_emit

.Lhalt:
    bl      gpio_led_toggle
    ldr     r0, =12500000
2:  subs    r0, #1
    bne     2b
    b       .Lhalt
