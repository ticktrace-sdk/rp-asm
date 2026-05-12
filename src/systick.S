@ =============================================================================
@ systick.S - ARMv8-M SysTick driver (M3-B core peripherals)
@
@ The SysTick is a 24-bit downcounter in the Cortex-M33 SCS.  At 150 MHz
@ (post-M2 clk_sys), the maximum reload that fits is:
@   2^24 / 150e6 = ~111.85 ms.
@ For longer periods, drop to the divided source (clk_sys / 8 = 18.75 MHz)
@ via CLKSOURCE=0; max period then becomes ~895 ms.
@
@ Public API:
@   systick_start_periodic (r0 = period_ticks_minus_1)
@                                       - RVR=N-1, CVR=0, CSR=ENABLE|TICKINT|CLKSOURCE
@   systick_stop                        - CSR=0
@   systick_get_value -> r0             - returns CVR
@
@ Cookbook for common 150 MHz periods (CLKSOURCE=1, processor clock):
@                  N         period
@   1 kHz       149_999    1 ms      (M2/M3 default)
@     100 Hz   1_499_999   10 ms
@      10 Hz  14_999_999  100 ms
@
@ Cycle budgets:
@   systick_start_periodic : ~6 cycles (3 stores)
@   systick_stop           : ~4 cycles (1 store)
@   systick_get_value      : ~3 cycles
@ =============================================================================

    .include "rp2350.inc"
    .include "systick.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ systick_start_periodic - configure SysTick for periodic interrupts.
@ Input  : r0 = reload value (ticks - 1)
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.systick_start_periodic, "ax"
    .thumb_func
    .global  systick_start_periodic
systick_start_periodic:
    @ Disable first to ensure a clean restart.
    ldr     r1, =SYST_CSR
    movs    r2, #0
    str     r2, [r1]                    @ CSR = 0

    @ Reload value (24-bit; HW will mask).
    ldr     r3, =SYST_RVR
    str     r0, [r3]

    @ Clear current value (any write clears).
    ldr     r3, =SYST_CVR
    str     r2, [r3]                    @ CVR = 0

    @ Re-enable: ENABLE | TICKINT | CLKSOURCE (clk_sys = processor clock).
    movs    r2, #(SYST_CSR_ENABLE | SYST_CSR_TICKINT | SYST_CSR_CLKSOURCE)
    str     r2, [r1]

    bx      lr

@ ----------------------------------------------------------------------------
@ systick_stop - disable counter and IRQ.
@ Clobbers: r0-r1.
@ ----------------------------------------------------------------------------
    .section .text.systick_stop, "ax"
    .thumb_func
    .global  systick_stop
systick_stop:
    ldr     r0, =SYST_CSR
    movs    r1, #0
    str     r1, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ systick_get_value -> r0 = CVR
@ Clobbers: r0.
@ ----------------------------------------------------------------------------
    .section .text.systick_get_value, "ax"
    .thumb_func
    .global  systick_get_value
systick_get_value:
    ldr     r0, =SYST_CVR
    ldr     r0, [r0]
    bx      lr
