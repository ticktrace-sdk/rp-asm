@ =============================================================================
@ spsc.S - Single-producer, single-consumer byte queue.
@
@ Public API (AAPCS):
@   spsc_byte_push(r0=q, r1=byte) -> r0           1 = pushed, 0 = full
@   spsc_byte_pop(r0=q) -> r0                     byte 0..255, or -1 if empty
@   spsc_byte_count(r0=q) -> r0                   bytes currently buffered
@   spsc_reset(r0=q)                              head = tail = 0
@
@ Correctness: same-CPU SPSC needs no DMB.  The producer only writes head;
@ the consumer only writes tail.  Reads of the other side's index are
@ word-aligned ldr (single-copy atomic on Cortex-M).
@
@ Cycle budgets (Cortex-M33 from SRAM):
@   spsc_byte_push (not full):  ~12 cycles
@   spsc_byte_pop  (not empty): ~10 cycles
@   spsc_byte_count:             ~8 cycles
@ =============================================================================

    .include "spsc.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ spsc_byte_push(r0 = q, r1 = byte) -> r0 = 1 (pushed) | 0 (full)
@ ----------------------------------------------------------------------------
    .section .text.spsc_byte_push, "ax"
    .thumb_func
    .global  spsc_byte_push
spsc_byte_push:
    push    {r4, lr}
    ldr     r2, [r0, #SPSC_OFF_HEAD]
    ldr     r3, [r0, #SPSC_OFF_MASK]
    adds    r12, r2, #1
    and     r12, r12, r3                @ r12 = next = (head + 1) & mask
    ldr     r4, [r0, #SPSC_OFF_TAIL]
    cmp     r12, r4
    bne     1f
    @ Full: leave head untouched, return 0
    movs    r0, #0
    pop     {r4, pc}
1:  @ data[head] = byte
    adds    r4, r0, #SPSC_OFF_DATA
    strb    r1, [r4, r2]
    @ Publish head LAST so the consumer never sees a half-written byte.
    @ Same-CPU SPSC; no DMB required (Cortex-M observes its own writes
    @ in program order).
    str     r12, [r0, #SPSC_OFF_HEAD]
    movs    r0, #1
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ spsc_byte_pop(r0 = q) -> r0 = byte | -1
@ ----------------------------------------------------------------------------
    .section .text.spsc_byte_pop, "ax"
    .thumb_func
    .global  spsc_byte_pop
spsc_byte_pop:
    ldr     r1, [r0, #SPSC_OFF_TAIL]
    ldr     r2, [r0, #SPSC_OFF_HEAD]
    cmp     r1, r2
    bne     1f
    @ Empty
    movs    r0, #0
    mvns    r0, r0                      @ r0 = -1
    bx      lr
1:  @ byte = data[tail]
    adds    r3, r0, #SPSC_OFF_DATA
    ldrb    r12, [r3, r1]
    @ tail = (tail + 1) & mask
    ldr     r3, [r0, #SPSC_OFF_MASK]
    adds    r1, r1, #1
    and     r1, r1, r3
    str     r1, [r0, #SPSC_OFF_TAIL]
    mov     r0, r12
    bx      lr

@ ----------------------------------------------------------------------------
@ spsc_byte_count(r0 = q) -> r0 = (head - tail) & mask
@ ----------------------------------------------------------------------------
    .section .text.spsc_byte_count, "ax"
    .thumb_func
    .global  spsc_byte_count
spsc_byte_count:
    ldr     r1, [r0, #SPSC_OFF_HEAD]
    ldr     r2, [r0, #SPSC_OFF_TAIL]
    ldr     r3, [r0, #SPSC_OFF_MASK]
    subs    r0, r1, r2
    and     r0, r0, r3
    bx      lr

@ ----------------------------------------------------------------------------
@ spsc_reset(r0 = q)
@   Force head = tail = 0.  NOT safe to call concurrently with push / pop.
@ ----------------------------------------------------------------------------
    .section .text.spsc_reset, "ax"
    .thumb_func
    .global  spsc_reset
spsc_reset:
    movs    r1, #0
    str     r1, [r0, #SPSC_OFF_HEAD]
    str     r1, [r0, #SPSC_OFF_TAIL]
    bx      lr
