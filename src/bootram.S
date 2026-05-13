@ =============================================================================
@ bootram.S - access helpers for the 1 KiB BOOTRAM region at 0x400E0000.
@
@ BOOTRAM is mostly used by the bootrom during initial boot and by
@ secure-boot / partition-table flows.  Once we're running as the main
@ application we don't invoke any of those services again (except the
@ explicit reset_to_bootsel hook in bootrom.S, which calls into ROM
@ rather than touching BOOTRAM directly), so we treat the whole 1 KiB
@ as application-usable scratch.
@
@ Public API:
@   bootram_zero            zero the entire 1 KiB region
@   bootram_get_base() -> r0   convenience for C bridge users
@
@ See include/bootram.inc for the address constants.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "bootram.inc"

@ ----------------------------------------------------------------------------
@ bootram_zero - clear BOOTRAM_BASE..BOOTRAM_END to 0.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.bootram_zero, "ax"
    .thumb_func
    .global  bootram_zero
bootram_zero:
    ldr     r0, =BOOTRAM_BASE
    ldr     r1, =BOOTRAM_END
    movs    r2, #0
    movs    r3, #0
1:  stmia   r0!, {r2, r3}
    cmp     r0, r1
    blo     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ bootram_get_base() -> r0 = BOOTRAM_BASE.
@ ----------------------------------------------------------------------------
    .section .text.bootram_get_base, "ax"
    .thumb_func
    .global  bootram_get_base
bootram_get_base:
    ldr     r0, =BOOTRAM_BASE
    bx      lr
