@ =============================================================================
@ examples/multicore_full_usb_demo.S - spinlock + mailbox + interp verification.
@
@ Builds on multicore_usb_demo with three additional dual-core
@ constructs, each independently observable in the CDC output:
@
@   SHARED COUNTER (spinlock):
@     Core 1 increments `shared_counter` under spin_lock(0).  Core 0
@     reads it under the same lock.  If spinlock works the count
@     advances monotonically.
@
@   MAILBOX (SIO FIFO):
@     Core 1 sends an incrementing word via multicore_fifo_push.
@     Core 0 pops via multicore_fifo_pop.  Proves inter-core message
@     passing.
@
@   INTERPOLATOR (SIO INTERP0):
@     Core 0 writes ACCUM0 = `shared_counter` snapshot and BASE0 =
@     1000, then peeks PEEK_LANE0.  Expected result = counter + 1000
@     (default CTRL = 0 -> result0 = ACCUM0 + BASE0).
@
@ Each second core 0 prints:
@   c0 iter=N spin=S mbox=M interp=I
@ Core 1 blinks GP25 at ~2 Hz independently.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .equ LED_PIN_BIT,        (1 << 25)
    .equ CORE1_STACK_SIZE,   1024
    .equ SHARED_SPINLOCK,    0

    .section .bss.core1_stack, "aw", %nobits
    .align   3
_core1_stack:
    .space   CORE1_STACK_SIZE
_core1_stack_top:

    .section .data.mc_full_state, "aw"
    .align   2
    .global  shared_counter
shared_counter: .word 0
    .global  last_mbox_word
last_mbox_word: .word 0
iter_count:     .word 0
c1_iter:        .word 0

    .section .rodata.mc_full_usb, "a"
banner_uart:    .asciz "rp-asm M6 - spinlock + mailbox + interp verification\r\n"
prefix_c0:      .asciz "c0 iter="
mid_spin:       .asciz " spin="
mid_mbox:       .asciz " mbox="
mid_interp:     .asciz " interp="
suffix_crlf:    .asciz "\r\n"

@ ----------------------------------------------------------------------------
@ _put_uint_decimal
@ ----------------------------------------------------------------------------
    .section .text._put_uint_decimal, "ax"
    .thumb_func
_put_uint_decimal:
    push    {r4, r5, r6, lr}
    sub     sp, sp, #12
    mov     r4, sp
    adds    r4, #11
    movs    r5, #0
    strb    r5, [r4]
    movs    r6, #10
    cbnz    r0, 1f
    subs    r4, #1
    movs    r5, #'0'
    strb    r5, [r4]
    b       2f
1:  udiv    r2, r0, r6
    mls     r3, r2, r6, r0
    adds    r3, #'0'
    subs    r4, #1
    strb    r3, [r4]
    mov     r0, r2
    cmp     r0, #0
    bne     1b
2:  mov     r0, r4
    bl      cdc_puts
    add     sp, sp, #12
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ core1_entry - per-core M33 prologue, then increment loop.
@ ----------------------------------------------------------------------------
    .section .text.core1_entry, "ax"
    .thumb_func
    .global  core1_entry
core1_entry:
    @ M33 prologue
    ldr     r0, =0xE000ED88
    movs    r1, #0xC0
    lsls    r1, #8
    str     r1, [r0]
    mrc     p7, #1, APSR_nzcv, c0, c0, #0
    bmi     1f
    mcrr    p7, #8, r0, r0, c0
    mcrr    p7, #8, r0, r0, c1
    sev
1:
    movs    r0, #0
    msr     msplim, r0

.Lc1_loop:
    @ Acquire spinlock 0, increment shared counter, release
    movs    r0, #SHARED_SPINLOCK
    bl      spin_lock_blocking
    ldr     r0, =shared_counter
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    movs    r0, #SHARED_SPINLOCK
    bl      spin_unlock

    @ Send our own iter count to core 0 via the FIFO mailbox
    ldr     r0, =c1_iter
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      multicore_fifo_push_blocking

    @ Toggle LED via SIO XOR
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_XOR
    ldr     r1, =LED_PIN_BIT
    str     r1, [r0]

    @ ~250 ms delay at 150 MHz
    ldr     r0, =12500000
2:  subs    r0, #1
    bne     2b
    b       .Lc1_loop

@ ----------------------------------------------------------------------------
@ main (core 0)
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner_uart
    bl      uart0_puts

    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ ---- INTERP0 setup ---------------------------------------------------
    @ CTRL_LANE0 with MASK_LSB=0, MASK_MSB=31 -> full 32-bit accumulator
    @ slice (the reset value of MASK_MSB is 0, which masks ACCUM down to
    @ a single bit and produces result = (ACCUM & 1) + BASE0).
    @ MASK_MSB lives at bits [14:10], so 31 << 10 = 0x7C00.
    movs    r0, #0                                @ INTERP0
    movs    r1, #0                                @ lane 0
    movw    r2, #0x7C00                           @ MASK_MSB=31, others=0
    bl      interp_set_ctrl
    movs    r0, #0
    movs    r1, #0
    movw    r2, #1000                             @ BASE0 = 1000
    bl      interp_set_base

    @ ---- Launch core 1 ---------------------------------------------------
    ldr     r0, =core1_entry
    ldr     r1, =_core1_stack_top
    ldr     r2, =_ram_vectors
    bl      multicore_launch_core1

.Lc0_loop:
    @ Drain any pending mailbox words and remember the last one
    ldr     r0, =SIO_BASE + 0x50                  @ SIO_FIFO_ST
1:  ldr     r1, [r0]
    tst     r1, #1                                @ VLD
    beq     2f
    bl      multicore_fifo_pop_blocking
    ldr     r1, =last_mbox_word
    str     r0, [r1]
    b       1b
2:
    @ Snapshot shared_counter under spinlock
    movs    r0, #SHARED_SPINLOCK
    bl      spin_lock_blocking
    ldr     r0, =shared_counter
    ldr     r4, [r0]                              @ r4 = snapshot
    movs    r0, #SHARED_SPINLOCK
    bl      spin_unlock

    @ Feed snapshot into INTERP0 ACCUM0 and peek
    movs    r0, #0
    movs    r1, #0
    mov     r2, r4
    bl      interp_set_accum
    movs    r0, #0
    movs    r1, #0
    bl      interp_peek                           @ r0 = ACCUM0 + BASE0 = snap + 1000
    mov     r5, r0

    @ Print one combined line
    ldr     r0, =prefix_c0
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      _put_uint_decimal

    ldr     r0, =mid_spin
    bl      cdc_puts
    mov     r0, r4
    bl      _put_uint_decimal

    ldr     r0, =mid_mbox
    bl      cdc_puts
    ldr     r0, =last_mbox_word
    ldr     r0, [r0]
    bl      _put_uint_decimal

    ldr     r0, =mid_interp
    bl      cdc_puts
    mov     r0, r5
    bl      _put_uint_decimal

    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ ~1 s pause
    ldr     r0, =50000000
3:  subs    r0, #1
    bne     3b
    b       .Lc0_loop

    .include "src/multicore.S"
    .include "src/spinlock.S"
    .include "src/interp.S"
    .include "src/nvic.S"
