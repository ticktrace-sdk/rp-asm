@ =============================================================================
@ multicore.S - RP2350 dual-core (M6 entry point).
@
@ Public API:
@   multicore_reset_core1                                disarm + reset core 1
@   multicore_launch_core1(entry, sp, vtable)            full launch handshake
@   multicore_fifo_drain                                 swallow any pending bytes
@   multicore_fifo_push_blocking(word) -> r0             spin on RDY, write
@   multicore_fifo_pop_blocking      -> r0               spin on VLD, read
@
@ Launch protocol (per pico-sdk multicore.c, also RP2350 datasheet 5.3):
@   Core 0 sends a 6-word command stream over the SIO inter-core FIFO and
@   verifies each word is echoed back by core 1 before sending the next:
@     0, 0, 1, vtable, sp, entry
@   On a mismatch the sequence restarts.  Before each `0` command we drain
@   the read FIFO + SEV (in case core 1 is in wfe waiting for the start).
@
@ Per-core M33 prologue (CPACR/RCP/MSPLIM) is the caller's responsibility on
@ core 1 - the entry point passed in must do whatever bring-up it needs.
@ See examples/multicore_usb_demo.S for a typical pattern.
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ SIO_FIFO_ST,        SIO_BASE + 0x050
    .equ SIO_FIFO_WR,        SIO_BASE + 0x054
    .equ SIO_FIFO_RD,        SIO_BASE + 0x058
    .equ FIFO_ST_VLD,        (1 << 0)
    .equ FIFO_ST_RDY,        (1 << 1)

    .equ PSM_BASE,           0x40018000
    .equ PSM_FRCE_OFF,       0x004
    .equ PSM_FRCE_OFF_PROC1, (1 << 24)
    .equ ATOMIC_SET_OFF,     0x2000
    .equ ATOMIC_CLR_OFF,     0x3000

@ ----------------------------------------------------------------------------
@ multicore_fifo_drain - read until VLD goes 0.  Clobbers r0-r1.
@ ----------------------------------------------------------------------------
    .section .text.multicore_fifo_drain, "ax"
    .thumb_func
    .global  multicore_fifo_drain
multicore_fifo_drain:
    ldr     r1, =SIO_FIFO_ST
1:  ldr     r0, [r1]
    tst     r0, #FIFO_ST_VLD
    beq     9f
    ldr     r0, =SIO_FIFO_RD
    ldr     r0, [r0]                        @ discard
    b       1b
9:  bx      lr

@ ----------------------------------------------------------------------------
@ multicore_fifo_push_blocking(word) - spin on RDY, write to WR.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.multicore_fifo_push_blocking, "ax"
    .thumb_func
    .global  multicore_fifo_push_blocking
multicore_fifo_push_blocking:
    ldr     r1, =SIO_FIFO_ST
1:  ldr     r2, [r1]
    tst     r2, #FIFO_ST_RDY
    beq     1b
    ldr     r1, =SIO_FIFO_WR
    str     r0, [r1]
    sev                                     @ wake other core if it's in wfe
    bx      lr

@ ----------------------------------------------------------------------------
@ multicore_fifo_pop_blocking -> r0 - spin on VLD, read from RD.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.multicore_fifo_pop_blocking, "ax"
    .thumb_func
    .global  multicore_fifo_pop_blocking
multicore_fifo_pop_blocking:
    ldr     r1, =SIO_FIFO_ST
1:  ldr     r2, [r1]
    tst     r2, #FIFO_ST_VLD
    bne     2f
    wfe                                     @ sleep until SEV from other core
    b       1b
2:  ldr     r1, =SIO_FIFO_RD
    ldr     r0, [r1]
    bx      lr

@ ----------------------------------------------------------------------------
@ multicore_reset_core1 - hold PROC1 in reset, then release.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.multicore_reset_core1, "ax"
    .thumb_func
    .global  multicore_reset_core1
multicore_reset_core1:
    @ Force PROC1 off via atomic SET
    ldr     r0, =PSM_BASE + ATOMIC_SET_OFF + PSM_FRCE_OFF
    ldr     r1, =PSM_FRCE_OFF_PROC1
    str     r1, [r0]
    @ Wait for it to actually take effect
    ldr     r0, =PSM_BASE + PSM_FRCE_OFF
1:  ldr     r2, [r0]
    tst     r2, #PSM_FRCE_OFF_PROC1
    beq     1b
    @ Release: atomic CLR
    ldr     r0, =PSM_BASE + ATOMIC_CLR_OFF + PSM_FRCE_OFF
    str     r1, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ multicore_launch_core1(entry, sp, vtable)
@   r0 = entry  (must have Thumb bit; will be ORed if not)
@   r1 = sp
@   r2 = vtable (vector-table base, ARMv8-M 128-byte aligned at minimum)
@
@ Sends the 6-word command sequence {0,0,1,vtable,sp,entry} over the SIO
@ FIFO and verifies each echo from core 1's bootrom.  On any mismatch the
@ whole sequence restarts.  Returns when core 1 has accepted the final
@ entry-point and is about to execute the user's code.
@
@ The command array is built on the stack so we don't need persistent data.
@ Clobbers: r0-r7, r12.
@ ----------------------------------------------------------------------------
    .section .text.multicore_launch_core1, "ax"
    .thumb_func
    .global  multicore_launch_core1
multicore_launch_core1:
    push    {r4, r5, r6, r7, lr}

    @ Ensure Thumb bit on entry
    orr     r0, r0, #1
    mov     r4, r0                              @ r4 = entry|1
    mov     r5, r1                              @ r5 = sp
    mov     r6, r2                              @ r6 = vtable

    @ Reset core 1 so the bootrom puts it in a known wait-for-launch state.
    bl      multicore_reset_core1

    @ Command array on the stack: cmd[0..5]
    @   sp[0]=0, sp[1]=0, sp[2]=1, sp[3]=vtable, sp[4]=sp_to_set, sp[5]=entry
    sub     sp, sp, #24
    movs    r0, #0
    str     r0, [sp, #0]
    str     r0, [sp, #4]
    movs    r0, #1
    str     r0, [sp, #8]
    str     r6, [sp, #12]                       @ vtable
    str     r5, [sp, #16]                       @ sp
    str     r4, [sp, #20]                       @ entry

.Lseq_restart:
    movs    r7, #0                              @ index 0..5

.Lseq_step:
    @ If cmd == 0, drain the FIFO first (handshake reset).
    lsls    r0, r7, #2
    ldr     r3, [sp, r0]
    cbnz    r3, .Lpush
    bl      multicore_fifo_drain
    sev
.Lpush:
    @ Push cmd
    lsls    r0, r7, #2
    ldr     r0, [sp, r0]
    bl      multicore_fifo_push_blocking
    @ Pop response
    bl      multicore_fifo_pop_blocking
    @ Compare to expected
    lsls    r1, r7, #2
    ldr     r2, [sp, r1]
    cmp     r0, r2
    bne     .Lseq_restart
    @ Advance
    adds    r7, #1
    cmp     r7, #6
    blt     .Lseq_step

    add     sp, sp, #24
    pop     {r4, r5, r6, r7, pc}
