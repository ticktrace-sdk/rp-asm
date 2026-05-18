@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ pwm.S - RP2350 PWM driver (M3-D)
@
@ Public API (see include/pwm.inc for register layout):
@   pwm_resets_enable                            release PWM block from reset
@   pwm_init                                     pwm_resets_enable + nothing else
@   pwm_set_clkdiv(slice, int, frac)             DIV = (int<<4) | frac
@   pwm_set_clkdiv_int(slice, int)               DIV = int<<4 (frac=0)
@   pwm_set_wrap(slice, top)                     TOP = top
@   pwm_set_chan_level(slice, chan, level)       STRH at CC + chan*2
@   pwm_set_both_levels(slice, level_a, level_b) CC = (b<<16) | a   (single STR)
@   pwm_set_phase_correct(slice, on)             CSR.PH_CORRECT via SET/CLR
@   pwm_set_output_polarity(slice, a_inv, b_inv) CSR.A_INV / B_INV via SET/CLR
@   pwm_set_enabled(slice, on)                   global EN bit via SET/CLR
@   pwm_get_counter(slice) -> r0                 read CTR
@   pwm_set_counter(slice, value)                write CTR
@   pwm_advance_count(slice)                     CSR.PH_ADV one-shot
@   pwm_retard_count(slice)                      CSR.PH_RET one-shot
@   pwm_irq_enable(slice, on)                    INTE bit via SET/CLR alias
@   pwm_acknowledge_irq(slice)                   write 1<<slice to INTR
@   pwm_set_freq_hz(slice, freq, src_hz)         compute DIV+TOP for ~freq Hz
@   pwm_set_gpio_function(pin)                   IO_BANK0 CTRL=4, clear ISO/OD
@
@ Cycle budgets (Cortex-M33, no wait states; see datasheet sec 12.5 + AAPCS):
@   pwm_set_chan_level:        ~6 cycles  (1 LSL + 1 ADD + 1 STRH + bx)
@   pwm_set_both_levels:       ~6 cycles  (1 LSL + 1 OR + 1 STR + bx)
@   pwm_set_enabled:           ~6 cycles  (1 LSL + 1 LDR + 1 STR + bx)
@   pwm_set_wrap:              ~6 cycles
@   pwm_set_clkdiv_int:        ~6 cycles
@   pwm_set_freq_hz:           ~30-50 cycles (UDIV-based math)
@
@ Atomic-alias paths (SET / CLR) are used wherever the firmware would
@ otherwise need to read-modify-write a shared register, so an ISR poking a
@ sibling slice can never lose an enable bit.
@ =============================================================================

    .include "rp2350.inc"
    .include "pwm.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ Internal calling convention:
@   Most slice-indexed entry points compute the slice base inline as
@       slice_base = PWM_BASE + slice * 20
@                  = PWM_BASE + (slice << 4) + (slice << 2)
@   This is two LSLs + one ADD (3 cycles) and avoids a constant-pool MUL.
@   r4 ends up holding the absolute slice base; the caller's slice argument
@   in r0 is destroyed in the process.  Functions that need both go through
@   a separate save (see pwm_set_freq_hz which keeps slice in r4 across calls).
@ ----------------------------------------------------------------------------

@ ----------------------------------------------------------------------------
@ pwm_resets_enable - clear RESETS_RESET.PWM bit, spin until RESET_DONE.PWM=1.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.pwm_resets_enable, "ax"
    .thumb_func
    .global  pwm_resets_enable
pwm_resets_enable:
    movs    r1, #1
    lsls    r1, #RESETS_pwm                 @ r1 = 1 << 16

    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]

    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ pwm_init - convenience wrapper.  Currently equivalent to pwm_resets_enable.
@ ----------------------------------------------------------------------------
    .section .text.pwm_init, "ax"
    .thumb_func
    .global  pwm_init
pwm_init:
    b       pwm_resets_enable

@ ----------------------------------------------------------------------------
@ pwm_set_clkdiv - DIV = (int<<4) | frac
@ Inputs:  r0 = slice, r1 = int_div (1..255), r2 = frac (0..15)
@ Cycles:  ~10 (slice math + lsl + or + str)
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_clkdiv, "ax"
    .thumb_func
    .global  pwm_set_clkdiv
pwm_set_clkdiv:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0                  @ r4 = slice * 20
    ldr     r0, =PWM_BASE
    adds    r4, r4, r0                  @ r4 = slice base

    lsls    r1, r1, #PWM_DIV_INT_LSB    @ r1 = int << 4
    orrs    r1, r1, r2                  @ r1 |= frac (already in [3:0])
    str     r1, [r4, #PWM_CH_DIV]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_clkdiv_int - DIV = int<<4 (frac forced to 0)
@ Inputs:  r0 = slice, r1 = int_div
@ Cycles:  ~8
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_clkdiv_int, "ax"
    .thumb_func
    .global  pwm_set_clkdiv_int
pwm_set_clkdiv_int:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0
    ldr     r0, =PWM_BASE
    adds    r4, r4, r0

    lsls    r1, r1, #PWM_DIV_INT_LSB
    str     r1, [r4, #PWM_CH_DIV]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_wrap - TOP = top
@ Inputs:  r0 = slice, r1 = top (16-bit)
@ Cycles:  ~7
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_wrap, "ax"
    .thumb_func
    .global  pwm_set_wrap
pwm_set_wrap:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0
    ldr     r0, =PWM_BASE
    adds    r4, r4, r0
    str     r1, [r4, #PWM_CH_TOP]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_chan_level - one 16-bit half-store at CC + chan*2.
@ Inputs:  r0 = slice, r1 = chan (0=A, 1=B), r2 = level (0..0xFFFF)
@ Cycles:  ~9 (slice math + index + STRH)
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_chan_level, "ax"
    .thumb_func
    .global  pwm_set_chan_level
pwm_set_chan_level:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0
    ldr     r0, =PWM_BASE
    adds    r4, r4, r0                  @ r4 = slice base

    @ Compute exact STRH address: CC + chan*2  (chan in {0,1})
    lsls    r1, r1, #1                  @ r1 = chan * 2
    adds    r4, r4, #PWM_CH_CC          @ r4 = &CC
    strh    r2, [r4, r1]                @ 16-bit half-store
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_both_levels - CC = (level_b << 16) | level_a in one STR.
@ Inputs:  r0 = slice, r1 = level_a (0..0xFFFF), r2 = level_b (0..0xFFFF)
@ Cycles:  ~9
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_both_levels, "ax"
    .thumb_func
    .global  pwm_set_both_levels
pwm_set_both_levels:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0
    ldr     r0, =PWM_BASE
    adds    r4, r4, r0

    lsls    r2, r2, #16
    orrs    r1, r1, r2                  @ r1 = (b<<16) | a
    str     r1, [r4, #PWM_CH_CC]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_phase_correct - flip CSR.PH_CORRECT via the atomic SET/CLR alias.
@ Inputs:  r0 = slice, r1 = on (0 or non-zero)
@ Cycles:  ~10
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_phase_correct, "ax"
    .thumb_func
    .global  pwm_set_phase_correct
pwm_set_phase_correct:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0                  @ r4 = slice * 20

    cmp     r1, #0
    bne     1f
    @ off -> CLR alias
    ldr     r0, =PWM_BASE + ATOMIC_CLR
    adds    r4, r4, r0
    movs    r1, #PWM_CSR_PH_CORRECT
    str     r1, [r4, #PWM_CH_CSR]
    pop     {r4, pc}
1:  @ on -> SET alias
    ldr     r0, =PWM_BASE + ATOMIC_SET
    adds    r4, r4, r0
    movs    r1, #PWM_CSR_PH_CORRECT
    str     r1, [r4, #PWM_CH_CSR]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_output_polarity - update CSR.A_INV / B_INV using SET+CLR aliases.
@ Inputs:  r0 = slice, r1 = a_inv (0/1), r2 = b_inv (0/1)
@
@ Performs both bits in one pair of writes:  bits to set go through SET,
@ bits to clear go through CLR.  Two stores total, no read-modify-write.
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_output_polarity, "ax"
    .thumb_func
    .global  pwm_set_output_polarity
pwm_set_output_polarity:
    push    {r4, r5, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0                  @ r4 = slice * 20

    @ Build SET mask (r3) and CLR mask (r5)
    movs    r3, #0
    movs    r5, #0
    cmp     r1, #0
    beq     1f
    movs    r3, #PWM_CSR_A_INV
1:  cmp     r2, #0
    beq     2f
    movs    r0, #PWM_CSR_B_INV
    orrs    r3, r3, r0
2:  @ CLR mask = inverse of SET mask within {A_INV, B_INV}
    movs    r5, #(PWM_CSR_A_INV | PWM_CSR_B_INV)
    bics    r5, r5, r3

    ldr     r0, =PWM_BASE + ATOMIC_SET
    adds    r0, r0, r4
    str     r3, [r0, #PWM_CH_CSR]

    ldr     r0, =PWM_BASE + ATOMIC_CLR
    adds    r0, r0, r4
    str     r5, [r0, #PWM_CH_CSR]

    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_enabled - toggle the global EN bit for `slice` via SET/CLR alias.
@ Inputs:  r0 = slice, r1 = on (0/non-zero)
@ Cycles:  ~7 (single 32-bit store to atomic alias)
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_enabled, "ax"
    .thumb_func
    .global  pwm_set_enabled
pwm_set_enabled:
    movs    r2, #1
    lsls    r2, r2, r0                  @ r2 = 1 << slice
    cmp     r1, #0
    bne     1f
    ldr     r0, =PWM_BASE + ATOMIC_CLR + PWM_EN
    str     r2, [r0]
    bx      lr
1:  ldr     r0, =PWM_BASE + ATOMIC_SET + PWM_EN
    str     r2, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ pwm_get_counter - r0 = CTR for slice in r0.
@ ----------------------------------------------------------------------------
    .section .text.pwm_get_counter, "ax"
    .thumb_func
    .global  pwm_get_counter
pwm_get_counter:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0
    ldr     r0, =PWM_BASE
    adds    r4, r4, r0
    ldr     r0, [r4, #PWM_CH_CTR]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_counter - CTR = value
@ Inputs:  r0 = slice, r1 = value (16-bit)
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_counter, "ax"
    .thumb_func
    .global  pwm_set_counter
pwm_set_counter:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0
    ldr     r0, =PWM_BASE
    adds    r4, r4, r0
    str     r1, [r4, #PWM_CH_CTR]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_advance_count / pwm_retard_count - one-shot pulse on CSR.PH_ADV/PH_RET.
@ The bit auto-clears in HW; we just write 1 via the SET alias.
@ ----------------------------------------------------------------------------
    .section .text.pwm_advance_count, "ax"
    .thumb_func
    .global  pwm_advance_count
pwm_advance_count:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0                  @ r4 = slice * 20
    ldr     r0, =PWM_BASE + ATOMIC_SET
    adds    r4, r4, r0
    movs    r1, #PWM_CSR_PH_ADV
    str     r1, [r4, #PWM_CH_CSR]
    pop     {r4, pc}

    .section .text.pwm_retard_count, "ax"
    .thumb_func
    .global  pwm_retard_count
pwm_retard_count:
    push    {r4, lr}
    lsls    r4, r0, #4
    lsls    r0, r0, #2
    adds    r4, r4, r0
    ldr     r0, =PWM_BASE + ATOMIC_SET
    adds    r4, r4, r0
    movs    r1, #PWM_CSR_PH_RET
    str     r1, [r4, #PWM_CH_CSR]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ pwm_irq_enable - INTE bit for `slice` via SET/CLR alias.
@ Inputs:  r0 = slice, r1 = on (0/non-zero)
@ ----------------------------------------------------------------------------
    .section .text.pwm_irq_enable, "ax"
    .thumb_func
    .global  pwm_irq_enable
pwm_irq_enable:
    movs    r2, #1
    lsls    r2, r2, r0
    cmp     r1, #0
    bne     1f
    ldr     r0, =PWM_BASE + ATOMIC_CLR + PWM_INTE
    str     r2, [r0]
    bx      lr
1:  ldr     r0, =PWM_BASE + ATOMIC_SET + PWM_INTE
    str     r2, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ pwm_acknowledge_irq - write 1<<slice to INTR (write-1-to-clear).
@ Input:  r0 = slice
@ ----------------------------------------------------------------------------
    .section .text.pwm_acknowledge_irq, "ax"
    .thumb_func
    .global  pwm_acknowledge_irq
pwm_acknowledge_irq:
    movs    r2, #1
    lsls    r2, r2, r0
    ldr     r0, =PWM_BASE + PWM_INTR
    str     r2, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ pwm_set_freq_hz - high-level helper.
@   Inputs:  r0 = slice, r1 = freq_hz, r2 = src_hz (typically clk_sys)
@
@ Strategy:
@   - Pick TOP = 0xFFFF (max 16-bit) initially, then scale down so the
@     resulting integer divider fits in the 8.4 fixed-point field.
@   - We aim for TOP between 1000 and 65535 to keep >0.1% duty resolution.
@
@ Compute: ticks_per_period = src_hz / freq_hz
@   if ticks_per_period < 65536: TOP = ticks_per_period - 1, DIV = 1.0
@   else: DIV.int = ceil(ticks_per_period / 65536), TOP = ticks_per_period / DIV.int - 1
@
@ DIV.frac is left at 0 here for simplicity / determinism; callers wanting
@ sub-Hz precision use pwm_set_clkdiv directly.
@
@ Cycle budget: ~30-50 cycles incl. one UDIV.
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_freq_hz, "ax"
    .thumb_func
    .global  pwm_set_freq_hz
pwm_set_freq_hz:
    push    {r4, r5, r6, lr}
    mov     r4, r0                      @ r4 = slice (preserved across calls)
    @ ticks_per_period = src_hz / freq_hz
    udiv    r6, r2, r1                  @ r6 = ticks

    @ DIV.int default = 1
    movs    r5, #1                      @ r5 = DIV.int
    movw    r3, #0xFFFF
    cmp     r6, r3
    bls     .Lpfreq_have_div            @ ticks <= 65535 -> DIV.int = 1
    @ DIV.int = ceil(ticks / 65536) = (ticks + 65535) >> 16
    adds    r6, r6, r3                  @ ticks + 65535
    lsrs    r5, r6, #16                 @ DIV.int
    @ Recompute TOP+1 = (src/freq) / DIV.int
    udiv    r6, r2, r1                  @ ticks again
    udiv    r6, r6, r5                  @ ticks / DIV.int

.Lpfreq_have_div:
    @ r5 = DIV.int, r6 = TOP+1
    @ Program TOP first
    mov     r0, r4
    subs    r1, r6, #1                  @ TOP = (TOP+1) - 1
    bl      pwm_set_wrap

    mov     r0, r4
    mov     r1, r5                      @ DIV.int
    bl      pwm_set_clkdiv_int

    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ pwm_set_gpio_function - route a pad to its PWM slice/channel.
@   1. Clear PADS_BANK0[pin].ISO and OD via atomic CLR.
@   2. Write IO_BANK0 GPIO[pin].CTRL = FUNCSEL=4.
@
@ Input:  r0 = pin (0..47).
@ Cycles: ~16 (two CLR stores + one CTRL store + 2 LDRs for base computation)
@ ----------------------------------------------------------------------------
    .section .text.pwm_set_gpio_function, "ax"
    .thumb_func
    .global  pwm_set_gpio_function
pwm_set_gpio_function:
    push    {r4, lr}
    mov     r4, r0                      @ r4 = pin

    @ ---- PADS_BANK0: clear ISO and OD ----
    @ pad register at offset 4 + pin*4
    lsls    r1, r4, #2                  @ pin * 4
    adds    r1, r1, #4                  @ + 4 (skip VOLTAGE_SELECT)
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR
    adds    r0, r0, r1
    movs    r2, #(0x180 >> 7)           @ keep operand small
    lsls    r2, r2, #7                  @ r2 = 0x180 = ISO|OD
    str     r2, [r0]

    @ ---- IO_BANK0: FUNCSEL = PWM (4) ----
    @ CTRL at offset 4 + pin*8
    lsls    r1, r4, #3                  @ pin * 8
    adds    r1, r1, #4
    ldr     r0, =IO_BANK0_BASE
    adds    r0, r0, r1
    movs    r2, #GPIO_FUNC_PWM          @ 4
    str     r2, [r0]

    pop     {r4, pc}
