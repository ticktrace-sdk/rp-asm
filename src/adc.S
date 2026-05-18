@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ adc.S - RP2350 ADC driver (M5-J)
@
@ Public API (AAPCS):
@   adc_init                                deassert RESETS, CS.EN=1
@   adc_select_input(r0=ch)                 program CS.AINSEL
@   adc_set_temp_sensor_enabled(r0=on)      CS.TS_EN
@   adc_set_round_robin(r0=mask)            CS.RROBIN[23:16]
@   adc_set_clkdiv(r0=int, r1=frac)         DIV = (int<<8) | frac
@   adc_read() -> r0                        START_ONCE, spin READY, return RESULT
@   adc_run(r0=on)                          START_MANY
@   adc_fifo_setup(r0=en, r1=dreq_en,       FCS = combined
@                  r2=threshold, r3=shift)
@   adc_fifo_get_blocking() -> r0           spin FCS.EMPTY clear, pop FIFO
@   adc_fifo_drain                          FCS write to clear
@ =============================================================================

    .include "adc.inc"
    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .text.adc_init, "ax"
    .thumb_func
    .global  adc_init
adc_init:
    movs    r1, #1
    lsls    r1, #RESETS_adc
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b
    @ CS = EN
    ldr     r0, =ADC_BASE
    movs    r1, #ADC_CS_EN
    str     r1, [r0, #ADC_CS]
    @ Wait for READY
2:  ldr     r1, [r0, #ADC_CS]
    tst     r1, #ADC_CS_READY
    beq     2b
    bx      lr

    .section .text.adc_select_input, "ax"
    .thumb_func
    .global  adc_select_input
adc_select_input:
    ldr     r3, =ADC_BASE
    ldr     r1, [r3, #ADC_CS]
    movs    r2, #0xF
    lsls    r2, #ADC_CS_AINSEL_SHIFT
    bic     r1, r1, r2
    and     r0, r0, #0xF
    lsls    r0, #ADC_CS_AINSEL_SHIFT
    orrs    r1, r0
    str     r1, [r3, #ADC_CS]
    bx      lr

    .section .text.adc_set_temp_sensor_enabled, "ax"
    .thumb_func
    .global  adc_set_temp_sensor_enabled
adc_set_temp_sensor_enabled:
    ldr     r3, =ADC_BASE
    ldr     r1, [r3, #ADC_CS]
    bic     r1, r1, #ADC_CS_TS_EN
    cmp     r0, #0
    beq     1f
    orrs    r1, r1, #ADC_CS_TS_EN
1:  str     r1, [r3, #ADC_CS]
    bx      lr

    .section .text.adc_set_round_robin, "ax"
    .thumb_func
    .global  adc_set_round_robin
adc_set_round_robin:
    ldr     r3, =ADC_BASE
    ldr     r1, [r3, #ADC_CS]
    movs    r2, #0xFF
    lsls    r2, #ADC_CS_RROBIN_SHIFT
    bic     r1, r1, r2
    and     r0, r0, #0xFF
    lsls    r0, #ADC_CS_RROBIN_SHIFT
    orrs    r1, r0
    str     r1, [r3, #ADC_CS]
    bx      lr

    .section .text.adc_set_clkdiv, "ax"
    .thumb_func
    .global  adc_set_clkdiv
adc_set_clkdiv:
    ldr     r3, =ADC_BASE
    lsls    r0, #8
    and     r1, #0xFF
    orrs    r0, r1
    str     r0, [r3, #ADC_DIV]
    bx      lr

    .section .text.adc_read, "ax"
    .thumb_func
    .global  adc_read
adc_read:
    ldr     r3, =ADC_BASE
    @ START_ONCE
    ldr     r1, [r3, #ADC_CS]
    orrs    r1, r1, #ADC_CS_START_ONCE
    str     r1, [r3, #ADC_CS]
    @ Spin READY
1:  ldr     r1, [r3, #ADC_CS]
    tst     r1, #ADC_CS_READY
    beq     1b
    ldr     r0, [r3, #ADC_RESULT]
    bx      lr

    .section .text.adc_run, "ax"
    .thumb_func
    .global  adc_run
adc_run:
    ldr     r3, =ADC_BASE
    ldr     r1, [r3, #ADC_CS]
    bic     r1, r1, #ADC_CS_START_MANY
    cmp     r0, #0
    beq     1f
    orrs    r1, r1, #ADC_CS_START_MANY
1:  str     r1, [r3, #ADC_CS]
    bx      lr

    .section .text.adc_fifo_setup, "ax"
    .thumb_func
    .global  adc_fifo_setup
adc_fifo_setup:
    @ r0=en, r1=dreq_en, r2=threshold(0..3), r3=shift(0/1)
    push    {r4}
    movs    r4, #0
    cmp     r0, #0
    beq     1f
    orrs    r4, r4, #ADC_FCS_EN
1:  cmp     r1, #0
    beq     2f
    orrs    r4, r4, #ADC_FCS_DREQ_EN
2:  cmp     r3, #0
    beq     3f
    orrs    r4, r4, #ADC_FCS_SHIFT
3:  and     r2, #0xF
    lsls    r2, #24                       @ THRESH[27:24]
    orrs    r4, r2
    ldr     r0, =ADC_BASE
    str     r4, [r0, #ADC_FCS]
    pop     {r4}
    bx      lr

    .section .text.adc_fifo_get_blocking, "ax"
    .thumb_func
    .global  adc_fifo_get_blocking
adc_fifo_get_blocking:
    ldr     r3, =ADC_BASE
1:  ldr     r1, [r3, #ADC_FCS]
    tst     r1, #ADC_FCS_EMPTY
    bne     1b
    ldr     r0, [r3, #ADC_FIFO]
    bx      lr

    .section .text.adc_fifo_drain, "ax"
    .thumb_func
    .global  adc_fifo_drain
adc_fifo_drain:
    ldr     r3, =ADC_BASE
1:  ldr     r1, [r3, #ADC_FCS]
    tst     r1, #ADC_FCS_EMPTY
    bne     2f
    ldr     r0, [r3, #ADC_FIFO]
    b       1b
2:  bx      lr
