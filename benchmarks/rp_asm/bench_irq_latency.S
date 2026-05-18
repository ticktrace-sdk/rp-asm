@ =============================================================================
@ bench_irq_latency.S: measure cycles from alarm-arm to first ISR instruction.
@
@ Method: arm TIMER0 ALARM0 for "current_us + 1000".  Just before the arming
@ store, sample DWT.  In the ISR, sample DWT again as the very first thing,
@ subtract, write to a shared word.  After ~100 ms wait, print the median of
@ 32 measurements.
@
@ Caveats:
@   - TIMER0 ticks at 1 MHz, so the 1 ms target window adds 1000 µs ×
@     150 cycles/µs = 150,000 cycles of unavoidable wait.  We subtract the
@     expected-fire offset from the raw delta to report just the IRQ-entry
@     latency.
@   - Hardware floor on Cortex-M33 IRQ entry is 12 cycles.  Anything above
@     that is wrapping overhead.
@ =============================================================================

    .include "trace.inc"

    @ Pull in timer + NVIC drivers (these aren't in DRIVER_SRC by default).
    .include "src/timer.S"
    .include "src/nvic.S"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ N_SAMPLES, 32
    .equ ALARM_DELAY_US, 1000
    .equ EXPECTED_BASE, 150000      @ 1000 µs * 150 cycles/µs
    .equ TIMER0_BASE_LOCAL, 0x400b0000
    .equ TIMER0_INTE, 0x38

    .section .rodata.bench_str, "a"
name_str:    .asciz "irq_latency"
metric_min:  .asciz "min_cycles"
metric_max:  .asciz "max_cycles"
metric_avg:  .asciz "avg_cycles"
banner:      .asciz "bench: TIMER0 ALARM0 IRQ latency, 32 samples\r\n"

    .section .bss.bench, "aw", %nobits
    .align 2
arm_cycle:   .word 0
isr_cycle:   .word 0
samples:     .space N_SAMPLES * 4
sample_idx:  .word 0

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      bench_standard_init
    bl      tick_init
    bl      timer_init

    ldr     r0, =banner
    bl      uart0_puts

    @ Install our ISR for TIMER0_IRQ_0 (NVIC line 0)
    ldr     r0, =bench_isr
    movs    r1, #0
    bl      nvic_install_handler
    movs    r0, #0                  @ TIMER0
    movs    r1, #0                  @ ALARM 0
    bl      alarm_clear_irq

    @ Enable INTE.ALARM_0 directly on TIMER0
    ldr     r0, =TIMER0_BASE_LOCAL + TIMER0_INTE
    movs    r1, #1
    str     r1, [r0]

    @ NVIC enable IRQ line 0 (TIMER0_IRQ_0)
    movs    r0, #0
    bl      nvic_enable_irq

    @ Enable CPU IRQs (in case startup left PRIMASK set; usually it's clear)
    cpsie   i

    @ N_SAMPLES iterations
    movs    r4, #N_SAMPLES
.Larm:
    @ Read current TIMER0 low word
    bl      time_us_32              @ r0 = current micros
    add     r2, r0, #ALARM_DELAY_US

    @ Sample DWT immediately before the arming store
    bl      dwt_cycles_read
    ldr     r3, =arm_cycle
    str     r0, [r3]

    movs    r0, #0                  @ timer 0
    movs    r1, #0                  @ alarm 0
    movs    r3, #0                  @ hi32 unused
    bl      alarm_set

    @ Spin until ISR records into isr_cycle (clears arm_cycle as a flag).
    ldr     r5, =isr_cycle
1:  ldr     r6, [r5]
    cmp     r6, #0
    beq     1b
    @ Clear for next iteration
    movs    r0, #0
    str     r0, [r5]

    subs    r4, #1
    bne     .Larm

    @ ---- Reduce samples → min / max / avg --------------------------------
    ldr     r7, =samples
    movs    r4, #N_SAMPLES
    ldr     r5, [r7], #4            @ r5 = min (and sum init)
    mov     r6, r5                  @ r6 = max
    mov     r8, r5                  @ r8 = sum
    subs    r4, #1
2:  ldr     r0, [r7], #4
    add     r8, r8, r0
    cmp     r0, r5
    bhs     3f
    mov     r5, r0
3:  cmp     r0, r6
    bls     4f
    mov     r6, r0
4:  subs    r4, #1
    bne     2b

    ldr     r0, =name_str
    ldr     r1, =metric_min
    mov     r2, r5
    bl      bench_emit
    ldr     r0, =name_str
    ldr     r1, =metric_max
    mov     r2, r6
    bl      bench_emit
    ldr     r0, =name_str
    ldr     r1, =metric_avg
    mov     r2, r8
    movs    r3, #N_SAMPLES
    udiv    r2, r2, r3
    bl      bench_emit

.Lhalt:
    bl      gpio_led_toggle
    ldr     r0, =12500000
5:  subs    r0, #1
    bne     5b
    b       .Lhalt

@ -----------------------------------------------------------------------------
@ ISR: TIMER0 ALARM0
@   FIRST instruction samples DWT, so the recorded delta really is from-the-
@   alarm-arm to we-are-in-the-ISR.  We subtract the expected 150_000 cycle
@   wait to isolate just the IRQ-entry overhead.
@ -----------------------------------------------------------------------------
    .section .text.bench_isr, "ax"
    .thumb_func
    .global  bench_isr
bench_isr:
    push    {r4, r5, r6, lr}
    ldr     r4, =DWT_BASE + DWT_CYCCNT
    ldr     r5, [r4]                @ now

    ldr     r6, =arm_cycle
    ldr     r6, [r6]
    subs    r5, r5, r6              @ raw delta
    ldr     r6, =EXPECTED_BASE
    subs    r5, r5, r6              @ subtract expected fire-time offset

    @ Stash into samples[sample_idx++]
    ldr     r6, =sample_idx
    ldr     r0, [r6]
    ldr     r4, =samples
    str     r5, [r4, r0, lsl #2]
    adds    r0, #1
    str     r0, [r6]

    @ Acknowledge alarm
    movs    r0, #0
    movs    r1, #0
    bl      alarm_clear_irq

    @ Wake the main loop: write a non-zero into isr_cycle
    ldr     r0, =isr_cycle
    movs    r1, #1
    str     r1, [r0]

    pop     {r4, r5, r6, pc}
