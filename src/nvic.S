@ =============================================================================
@ nvic.S - ARMv8-M NVIC helpers (M3-B core peripherals)
@
@ Public API:
@   nvic_enable_irq      (r0 = irq_num)              - ISER[irq/32] |= 1<<(irq%32)
@   nvic_disable_irq     (r0 = irq_num)              - ICER[irq/32] |= 1<<(irq%32)
@   nvic_set_pending     (r0 = irq_num)              - ISPR[irq/32] |= 1<<(irq%32)
@   nvic_clear_pending   (r0 = irq_num)              - ICPR[irq/32] |= 1<<(irq%32)
@   nvic_set_priority    (r0 = irq_num, r1 = prio)   - IPR[irq] = prio<<4
@   nvic_install_handler (r0 = irq_num, r1 = handler_addr)
@                                                    - vector[16+irq] = handler|1
@
@ Vector-table strategy:
@   startup.S allocates _vectors in .vectors which the linker places at the
@   start of SRAM (0x20000000).  SRAM is writable, so we simply patch the
@   word at *VTOR + 16*4 + irq_num*4*.  No copy required.  We OR in the
@   Thumb bit so the caller can pass either an aligned function pointer or
@   one with the Thumb bit already set.
@
@ Cycle budgets:
@   nvic_enable_irq      : ~6 cycles (1 ldr, 1 add, 1 lsl, 1 str)
@   nvic_set_priority    : ~7 cycles
@   nvic_install_handler : ~6 cycles (read VTOR, compute, str)
@ =============================================================================

    .include "rp2350.inc"
    .include "systick.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ nvic_enable_irq - set the enable bit for IRQ r0.
@ Input  : r0 = irq_num (0..N-1)
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.nvic_enable_irq, "ax"
    .thumb_func
    .global  nvic_enable_irq
nvic_enable_irq:
    @ word_idx = irq >> 5;  bit_pos = irq & 31
    lsrs    r1, r0, #5
    and     r0, r0, #31
    movs    r2, #1
    lsls    r2, r2, r0                  @ mask
    ldr     r3, =NVIC_ISER_BASE
    str     r2, [r3, r1, lsl #2]        @ ISER[word_idx] |= mask
    bx      lr

@ ----------------------------------------------------------------------------
@ nvic_disable_irq - clear the enable bit for IRQ r0.
@ ----------------------------------------------------------------------------
    .section .text.nvic_disable_irq, "ax"
    .thumb_func
    .global  nvic_disable_irq
nvic_disable_irq:
    lsrs    r1, r0, #5
    and     r0, r0, #31
    movs    r2, #1
    lsls    r2, r2, r0
    ldr     r3, =NVIC_ICER_BASE
    str     r2, [r3, r1, lsl #2]
    bx      lr

@ ----------------------------------------------------------------------------
@ nvic_set_pending - force-pend IRQ r0 (mostly useful for tests).
@ ----------------------------------------------------------------------------
    .section .text.nvic_set_pending, "ax"
    .thumb_func
    .global  nvic_set_pending
nvic_set_pending:
    lsrs    r1, r0, #5
    and     r0, r0, #31
    movs    r2, #1
    lsls    r2, r2, r0
    ldr     r3, =NVIC_ISPR_BASE
    str     r2, [r3, r1, lsl #2]
    bx      lr

@ ----------------------------------------------------------------------------
@ nvic_clear_pending - clear the pending bit.
@ ----------------------------------------------------------------------------
    .section .text.nvic_clear_pending, "ax"
    .thumb_func
    .global  nvic_clear_pending
nvic_clear_pending:
    lsrs    r1, r0, #5
    and     r0, r0, #31
    movs    r2, #1
    lsls    r2, r2, r0
    ldr     r3, =NVIC_ICPR_BASE
    str     r2, [r3, r1, lsl #2]
    bx      lr

@ ----------------------------------------------------------------------------
@ nvic_set_priority - write the 8-bit priority byte for IRQ r0.
@ Input  : r0 = irq_num, r1 = priority (0=highest, 0xF=lowest on M33 4-bit)
@
@ The NVIC IPR registers are byte-addressable; each IRQ takes 1 byte.  Only
@ the high N bits of each byte are implemented (Cortex-M33 = 4 bits, so we
@ shift the user's priority left by 4 so callers can pass 0..15 directly).
@
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.nvic_set_priority, "ax"
    .thumb_func
    .global  nvic_set_priority
nvic_set_priority:
    @ priority byte at NVIC_IPR_BASE + irq
    ldr     r2, =NVIC_IPR_BASE
    add     r2, r2, r0
    lsls    r1, r1, #4                  @ shift into the 4 implemented bits
    strb    r1, [r2]
    bx      lr

@ ----------------------------------------------------------------------------
@ nvic_install_handler - patch vector entry for IRQ r0 to point at r1.
@ Input  : r0 = irq_num, r1 = handler addr (Thumb bit optional)
@ Clobbers: r0-r3.
@
@ Vector entry address = *VTOR + 16*4 + irq_num*4
@ We OR the Thumb bit into the handler so callers can pass &fn directly.
@ ----------------------------------------------------------------------------
    .section .text.nvic_install_handler, "ax"
    .thumb_func
    .global  nvic_install_handler
nvic_install_handler:
    ldr     r2, =SCB_VTOR
    ldr     r2, [r2]                    @ r2 = vector base in RAM
    add     r2, r2, #NVIC_VECTOR_IRQ_OFFSET  @ + 0x40 = IRQ 0 slot
    orr     r1, r1, #1                  @ ensure Thumb bit
    str     r1, [r2, r0, lsl #2]        @ vec[16+irq] = handler|1
    bx      lr
