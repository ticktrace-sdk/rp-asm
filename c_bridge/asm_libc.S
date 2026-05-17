@ =============================================================================
@ c_bridge/asm_libc.S — minimal libc replacements for gcc-emitted calls.
@
@ gcc lowers struct copies, large initializers, and array fills into calls
@ to memcpy / memset / memcmp.  These are word-stride implementations
@ tuned for Cortex-M33 — small (~50 bytes each) and cache-friendly.
@
@ All AAPCS-clean: r0 (return) = first arg, no callee-saved clobber.
@
@ Cycle budgets (Cortex-M33 from SRAM, n = byte count):
@   memset:  ~5 + 3*n/4 + tail   cycles
@   memcpy:  ~5 + 4*n/4 + tail   cycles
@   memcmp:  ~5 + 5*n             cycles (byte-stride for simplicity)
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ---------------------------------------------------------------- memset
@ void *memset(void *dst, int c, size_t n)
@   r0 = dst, r1 = byte (only low 8 bits used), r2 = n bytes
@   Returns dst in r0.
    .section .text.memset, "ax"
    .thumb_func
    .global  memset
memset:
    push    {r4, lr}
    mov     r4, r0                  @ save dst for return
    and     r1, r1, #0xFF
    orr     r1, r1, r1, lsl #8
    orr     r1, r1, r1, lsl #16     @ r1 = c repeated 4 times

    @ Word-stride fast path while n >= 4 and dst aligned
    tst     r0, #3
    bne     2f                      @ misaligned start -> bytes
1:  cmp     r2, #4
    blo     2f
    str     r1, [r0], #4
    subs    r2, #4
    b       1b

    @ Byte tail
2:  cmp     r2, #0
    beq     3f
    strb    r1, [r0], #1
    subs    r2, #1
    b       2b

3:  mov     r0, r4
    pop     {r4, pc}

@ ---------------------------------------------------------------- memcpy
@ void *memcpy(void *dst, const void *src, size_t n)
    .section .text.memcpy, "ax"
    .thumb_func
    .global  memcpy
memcpy:
    push    {r4, lr}
    mov     r4, r0                  @ save dst for return

    @ Word-stride fast path: both src and dst word-aligned and n >= 4
    orr     r3, r0, r1
    tst     r3, #3
    bne     2f
1:  cmp     r2, #4
    blo     2f
    ldr     r3, [r1], #4
    str     r3, [r0], #4
    subs    r2, #4
    b       1b

    @ Byte tail / unaligned fallback
2:  cmp     r2, #0
    beq     3f
    ldrb    r3, [r1], #1
    strb    r3, [r0], #1
    subs    r2, #1
    b       2b

3:  mov     r0, r4
    pop     {r4, pc}

@ ---------------------------------------------------------------- memcmp
@ int memcmp(const void *a, const void *b, size_t n)
@   Returns 0 if equal, otherwise (a[i] - b[i]) at first mismatch.
    .section .text.memcmp, "ax"
    .thumb_func
    .global  memcmp
memcmp:
1:  cmp     r2, #0
    beq     2f
    ldrb    r3, [r0], #1
    ldrb    ip, [r1], #1
    subs    r3, r3, ip
    bne     3f
    subs    r2, #1
    b       1b
2:  movs    r0, #0
    bx      lr
3:  mov     r0, r3
    bx      lr
