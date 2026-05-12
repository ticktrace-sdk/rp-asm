@ =============================================================================
@ tick.S - start the 1 us tick generators for TIMER0/1, WATCHDOG.
@
@ Datasheet ref: RP2350 sec 8.5.
@
@ The TICKS peripheral has six independent sub-tickers (PROC0, PROC1,
@ TIMER0, TIMER1, WATCHDOG, RISCV).  Each one divides clk_ref down to a
@ tick rate.  With clk_ref = XOSC = 12 MHz and CYCLES = 12 we get a 1 MHz
@ (1 us) tick - the value the SDK uses by convention for TIMER0/1 and
@ the watchdog.
@
@ tick_init programs CYCLES=12 and asserts CTRL.ENABLE on all four tickers
@ that the firmware actually uses.  PROC0/PROC1/RISCV ticks are for the
@ SysTick reload on each core; we leave those alone for now (M3 will turn
@ them on as part of the SysTick driver).
@
@ Cycle budget: 4 sub-tickers * 2 stores = ~16 cycles end-to-end.
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ tick_init - turn on TIMER0/TIMER1/WATCHDOG ticks at 1 MHz.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.tick_init, "ax"
    .thumb_func
    .global  tick_init
tick_init:
    ldr     r0, =TICKS_BASE
    movs    r1, #TICKS_CYCLES_DIV_1MHZ      @ 12
    movs    r2, #TICKS_CTRL_ENABLE          @ 1

    @ TIMER0
    str     r1, [r0, #(TICKS_TIMER0_OFFS + TICKS_CYCLES)]
    str     r2, [r0, #(TICKS_TIMER0_OFFS + TICKS_CTRL)]

    @ TIMER1
    str     r1, [r0, #(TICKS_TIMER1_OFFS + TICKS_CYCLES)]
    str     r2, [r0, #(TICKS_TIMER1_OFFS + TICKS_CTRL)]

    @ WATCHDOG
    str     r1, [r0, #(TICKS_WATCHDOG_OFFS + TICKS_CYCLES)]
    str     r2, [r0, #(TICKS_WATCHDOG_OFFS + TICKS_CTRL)]

    bx      lr
