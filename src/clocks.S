@ =============================================================================
@ clocks.S - clock-tree muxing for the M2 "fast" config.
@
@ Datasheet ref: RP2350 sec 8.1.
@
@ Boot state (post-bootrom): clk_ref = clk_sys = ROSC at ~6 MHz; clk_peri
@ disabled.  We:
@
@   1. Make sure clk_sys is sourced from clk_ref while we touch the AUX mux,
@      so a transient on aux can't propagate into clk_sys (sec 8.1.4).
@   2. Switch clk_ref to XOSC.
@   3. Set clk_sys.AUXSRC = PLL_SYS, then SRC = AUX.
@   4. clk_peri.AUXSRC = PLL_SYS, ENABLE.
@   5. clk_usb / clk_adc both on PLL_USB.
@
@ Cycle budget end-to-end (excluding the LOCK / SELECTED waits):
@   ~80 cycles of stores + register loads, plus 4 small spin loops on
@   per-clock SELECTED bits (each ~10 cycles when the mux settles).
@
@ Total expected: ~150 cycles real silicon.
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ clocks_init - configure the M2 clock tree.
@ Pre: xosc_init, pll_sys_*, pll_usb_* have all completed.
@ Clobbers: r0-r4.
@ ----------------------------------------------------------------------------
    .section .text.clocks_init, "ax"
    .thumb_func
    .global  clocks_init
clocks_init:
    push    {r4, lr}
    ldr     r4, =CLOCKS_BASE

    @ ---- 1. Park clk_sys on clk_ref so we can safely retune AUX -----------
    @ CLK_SYS_CTRL.SRC = REF (bit 0 = 0).  AUXSRC field is left at default;
    @ we rewrite the whole register since we know what we want.
    movs    r0, #CLK_SYS_SRC_REF
    str     r0, [r4, #(CLOCKS_CLK_SYS + CLK_CTRL)]

    @ Wait for SELECTED to reflect SRC=REF (bit 0 of SELECTED is one-hot).
1:  ldr     r0, [r4, #(CLOCKS_CLK_SYS + CLK_SELECTED)]
    cmp     r0, #1
    bne     1b

    @ ---- 2. clk_ref = XOSC ------------------------------------------------
    movs    r0, #CLK_REF_SRC_XOSC
    str     r0, [r4, #(CLOCKS_CLK_REF + CLK_CTRL)]
    @ SELECTED for clk_ref is one-hot of SRC: XOSC corresponds to bit 2 (=4).
2:  ldr     r0, [r4, #(CLOCKS_CLK_REF + CLK_SELECTED)]
    cmp     r0, #4
    bne     2b

    @ ---- 3. clk_sys: AUXSRC=PLL_SYS, then SRC=AUX -------------------------
    movs    r0, #CLK_SYS_AUXSRC_PLL_SYS    @ bits [7:5] = 0 (PLL_SYS)
    str     r0, [r4, #(CLOCKS_CLK_SYS + CLK_CTRL)]
    @ Now flip SRC=AUX
    movs    r0, #(CLK_SYS_AUXSRC_PLL_SYS | CLK_SYS_SRC_AUX)
    str     r0, [r4, #(CLOCKS_CLK_SYS + CLK_CTRL)]
3:  ldr     r0, [r4, #(CLOCKS_CLK_SYS + CLK_SELECTED)]
    cmp     r0, #2                          @ AUX is bit 1
    bne     3b

    @ ---- 4. clk_peri = clk_sys (AUXSRC = CLK_SYS = 0), ENABLE -------------
    @ No glitchless mux on clk_peri - must disable before reprogramming
    @ (datasheet sec 8.1.4).  Atomic CLR on ENABLE bit.
    ldr     r0, =CLOCKS_BASE + ATOMIC_CLR + CLOCKS_CLK_PERI + CLK_CTRL
    movs    r1, #(1 << 11)
    str     r1, [r0]

    @ Now set source + enable
    movs    r0, #(CLK_PERI_AUXSRC_SYS | CLK_PERI_ENABLE)
    str     r0, [r4, #(CLOCKS_CLK_PERI + CLK_CTRL)]

    @ ---- 5. clk_usb = PLL_USB / 1, ENABLE ---------------------------------
    ldr     r0, =CLOCKS_BASE + ATOMIC_CLR + CLOCKS_CLK_USB + CLK_CTRL
    movs    r1, #(1 << 11)
    str     r1, [r0]
    movs    r0, #(CLK_USBADC_AUXSRC_PLL_USB | CLK_USBADC_ENABLE)
    str     r0, [r4, #(CLOCKS_CLK_USB + CLK_CTRL)]

    @ ---- 6. clk_adc = PLL_USB / 1, ENABLE ---------------------------------
    ldr     r0, =CLOCKS_BASE + ATOMIC_CLR + CLOCKS_CLK_ADC + CLK_CTRL
    movs    r1, #(1 << 11)
    str     r1, [r0]
    movs    r0, #(CLK_USBADC_AUXSRC_PLL_USB | CLK_USBADC_ENABLE)
    str     r0, [r4, #(CLOCKS_CLK_ADC + CLK_CTRL)]

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ clocks_post_pll_uart_baud_fixup - rewrite UART0 IBRD/FBRD for clk_peri=150 MHz.
@ Must be called *after* clocks_init has switched clk_peri to PLL_SYS.
@
@ The PL011 datasheet (TRM) says IBRD/FBRD should be reprogrammed and then
@ a write to LCR_H is required to commit the latch.  We re-write LCR_H to
@ the same value uart0_init left there (0x70 = WLEN=3, FEN=1).
@
@ Clobbers: r0-r2.
@ ----------------------------------------------------------------------------
    .section .text.clocks_post_pll_uart_baud_fixup, "ax"
    .thumb_func
    .global  clocks_post_pll_uart_baud_fixup
clocks_post_pll_uart_baud_fixup:
    ldr     r0, =UART0_BASE

    movs    r1, #UART_IBRD_150MHZ           @ 81
    str     r1, [r0, #UART_IBRD]
    movs    r1, #UART_FBRD_150MHZ           @ 24
    str     r1, [r0, #UART_FBRD]

    movs    r1, #0x70                       @ commit baud latch
    str     r1, [r0, #UART_LCR_H]

    bx      lr
