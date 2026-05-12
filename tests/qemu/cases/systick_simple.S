@ EXPECT: systick ok
@ =============================================================================
@ systick_simple.S - exercise ARMv8-M SysTick on QEMU's mps2-an505 board.
@
@ The Cortex-M33 SysTick at 0xE000E010 is a generic ARMv8-M peripheral, so
@ this case runs unmodified on the QEMU MPS2 platform.  We deliberately do
@ NOT use IRQs (semihosting only works from thread mode on QEMU's MPS2
@ port), and instead poll COUNTFLAG via CSR reads.
@
@ Test:
@   - Load RVR = 999  (so period = 1000 ticks)
@   - Enable SysTick (no IRQ, processor clock as source)
@   - Wait for COUNTFLAG to come up 10 times by re-reading CSR
@   - Print "systick ok\n" via SYS_WRITE0 and SYS_EXIT_EXTENDED(0)
@
@ COUNTFLAG (bit 16) is "set when the timer counts down to zero, cleared by
@ a read of CSR" - exactly the one-shot semantics we want for polling.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ SYS_WRITE0,         0x04
    .equ SYS_EXIT_EXTENDED,  0x20
    .equ ADP_AppExit,        0x20026

    .equ SYST_CSR,           0xE000E010
    .equ SYST_RVR,           0xE000E014
    .equ SYST_CVR,           0xE000E018

    .equ CSR_ENABLE,         (1 << 0)
    .equ CSR_CLKSOURCE,      (1 << 2)
    .equ CSR_COUNTFLAG,      (1 << 16)

    .equ N_WRAPS,            10

@ ----------------------------------------------------------------- vectors
    .section .vectors, "ax"
    .align   2
    .global _vectors
_vectors:
    .word _stack_top
    .word _start + 1
    .word _hang  + 1
    .word _hang  + 1
    .word _hang  + 1
    .word _hang  + 1
    .word _hang  + 1
    .word _hang  + 1
    .word 0
    .word 0
    .word 0
    .word _hang  + 1
    .word _hang  + 1
    .word 0
    .word _hang  + 1
    .word _hang  + 1            @ SysTick - we don't use the IRQ here

@ ----------------------------------------------------------------- rodata
    .section .rodata, "a"
ok_msg:   .asciz "systick ok\n"
fail_msg: .asciz "systick fail\n"

    .align 2
ok_block:   .word ADP_AppExit
            .word 0
fail_block: .word ADP_AppExit
            .word 1

@ ----------------------------------------------------------------- text
    .section .text, "ax"
    .thumb_func
    .global _start
_start:
    @ ---- Configure: RVR = 999, CVR = 0, CSR = ENABLE | CLKSOURCE -----
    ldr     r0, =SYST_CSR
    movs    r1, #0
    str     r1, [r0]                @ CSR = 0 (disable while we config)

    ldr     r2, =SYST_RVR
    movw    r1, #999
    str     r1, [r2]                @ RVR = 999

    ldr     r2, =SYST_CVR
    str     r1, [r2]                @ writing any value clears CVR

    movs    r1, #(CSR_ENABLE | CSR_CLKSOURCE)
    str     r1, [r0]                @ CSR = ENABLE | CLKSOURCE (no IRQ)

    @ ---- Poll COUNTFLAG 10 times -----------------------------------
    @ COUNTFLAG (bit 16) goes high on wrap, clears on CSR read.
    movs    r4, #0                  @ wraps observed
    @ Cap iterations so we exit even if SysTick never fires (test fail).
    @ At 24 MHz CPU clock with period 1000, each wrap is 41 us, so 10
    @ wraps come in well under 1 ms.  We give it 10M poll iterations as
    @ a safety net.
    movw    r5, #0xFFFF
    movt    r5, #0x00FF             @ ~16M
1:  ldr     r1, [r0]                @ read CSR (clears COUNTFLAG)
    movw    r2, #0
    movt    r2, #0x0001             @ 1 << 16 = COUNTFLAG mask
    tst     r1, r2
    beq     2f
    adds    r4, r4, #1
    cmp     r4, #N_WRAPS
    bge     .Ldone
2:  subs    r5, r5, #1
    bne     1b

    @ Fell out of the timeout loop with too few wraps.
    movs    r0, #SYS_WRITE0
    ldr     r1, =fail_msg
    bkpt    0xab
    movs    r0, #SYS_EXIT_EXTENDED
    ldr     r1, =fail_block
    bkpt    0xab

.Ldone:
    @ Disable SysTick before exit so QEMU doesn't keep ticking.
    ldr     r0, =SYST_CSR
    movs    r1, #0
    str     r1, [r0]

    movs    r0, #SYS_WRITE0
    ldr     r1, =ok_msg
    bkpt    0xab

    movs    r0, #SYS_EXIT_EXTENDED
    ldr     r1, =ok_block
    bkpt    0xab

.Lspin:
    b       .Lspin

    .thumb_func
_hang:
    b       _hang
