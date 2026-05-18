@ =============================================================================
@ c_bridge/runtime.S: C runtime helpers on top of src/startup.S.
@
@ Our SRAM-resident image is loaded via UF2 with .data already in place,
@ so we don't need a .data copy.  But C globals + statics may live in
@ .bss, and C expects them to read as zero.  This file provides:
@
@   _c_runtime_init       Called by the user's main (or a wrapper) before
@                         dropping into the first C function.  Zeroes
@                         .bss using the linker symbols __bss_start__ and
@                         __bss_end__ (defined in link/sram.ld).
@
@ AAPCS-clean: clobbers r0-r3, returns via bx lr.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .text._c_runtime_init, "ax"
    .thumb_func
    .global  _c_runtime_init
_c_runtime_init:
    ldr     r0, =__bss_start__
    ldr     r1, =__bss_end__
    movs    r2, #0
1:  cmp     r0, r1
    bhs     2f
    str     r2, [r0], #4
    b       1b
2:  bx      lr
