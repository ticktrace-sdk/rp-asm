@ =============================================================================
@ bench_sched_post.S: post-to-task-entry latency, 32 samples.
@
@ Setup:
@   - Standard 150 MHz clock bring-up
@   - DWT enabled
@   - One soft task at the highest priority; its first instructions sample
@     DWT_CYCCNT into a buffer
@   - Main is in thread mode (priority lower than any IRQ), so task_post
@     causes immediate preemption
@
@ Measurement: from the cycle just BEFORE the STR-to-NVIC_ISPR inside
@ task_post to the cycle the task body samples DWT_CYCCNT.  This includes:
@   - 2..3 cycles of task_post epilogue (str + bx lr)
@   - 12 cycles hardware IRQ entry (Cortex-M33 architectural floor)
@   - 4..6 cycles task prologue (push, ldr DWT_BASE, ldr CYCCNT)
@ Total prediction: ~20-25 cycles.
@
@ Output: BENCH name=sched_post metric={min,max,avg}_cycles value=0x...
@ =============================================================================

    .include "trace.inc"
    .include "sched.inc"

    .include "src/nvic.S"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ N_SAMPLES, 32

    .section .rodata.bench, "a"
name_str:     .asciz "sched_post"
metric_min:   .asciz "min_cycles"
metric_max:   .asciz "max_cycles"
metric_avg:   .asciz "avg_cycles"
banner:       .asciz "bench: task_post -> task entry latency, 32 samples\r\n"

    .section .bss.bench, "aw", %nobits
    .align 2
arm_cycle:    .word 0
samples:      .space N_SAMPLES * 4
sample_idx:   .word 0
done_flag:    .word 0

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      bench_standard_init                @ clocks + UART + DWT
    bl      sched_init

    @ Install our soft task at id 0 / highest priority
    movs    r0, #0
    ldr     r1, =sched_post_target
    movs    r2, #0x00
    bl      task_create

    @ Reset sample state
    ldr     r0, =sample_idx
    movs    r1, #0
    str     r1, [r0]

    ldr     r0, =banner
    bl      uart0_puts

    @ Enable IRQs once
    cpsie   i

    movs    r4, #N_SAMPLES
.Lloop:
    @ Clear done flag
    ldr     r0, =done_flag
    movs    r1, #0
    str     r1, [r0]

    @ Sample t0 immediately before the post.  The "post" is just a single
    @ STR inside task_post; the call/return overhead either side is the
    @ same on every iteration so it doesn't affect the relative delta.
    bl      dwt_cycles_read
    ldr     r1, =arm_cycle
    str     r0, [r1]

    movs    r0, #0
    bl      task_post

    @ The task pre-empts here and runs to completion.  When it returns,
    @ done_flag is non-zero and samples[idx] has been written.
    ldr     r0, =done_flag
1:  ldr     r1, [r0]
    cmp     r1, #0
    beq     1b

    subs    r4, #1
    bne     .Lloop

    @ ---- Reduce min / max / avg ------------------------------------------
    ldr     r7, =samples
    ldr     r5, [r7], #4
    mov     r6, r5
    mov     r8, r5
    movs    r4, #(N_SAMPLES - 1)
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
@ Soft task target.  Its first three instructions read DWT.CYCCNT, so the
@ measurement window stops here.
@ -----------------------------------------------------------------------------
    .section .text.sched_post_target, "ax"
    .thumb_func
    .global  sched_post_target
sched_post_target:
    @ Sample DWT.CYCCNT as the FIRST data instruction.
    ldr     r0, =DWT_BASE + DWT_CYCCNT
    ldr     r0, [r0]                          @ "now"

    @ Compute delta against arm_cycle
    ldr     r1, =arm_cycle
    ldr     r1, [r1]
    subs    r0, r0, r1

    @ Stash in samples[sample_idx++]
    ldr     r2, =sample_idx
    ldr     r3, [r2]
    ldr     r1, =samples
    str     r0, [r1, r3, lsl #2]
    adds    r3, #1
    str     r3, [r2]

    @ Wake main
    ldr     r1, =done_flag
    movs    r0, #1
    str     r0, [r1]
    bx      lr
