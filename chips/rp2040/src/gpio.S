@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ gpio.S - RP2040 GPIO / PADS driver (M2 scope).
@
@ Covers all 30 user GPIOs in IO_BANK0 + PADS_BANK0.  Every store is to an
@ atomic alias window - no read-modify-write hazards even if an ISR mutates
@ a sibling pad mid-call.
@
@ Unlike RP2350 there is no ISO bit on RP2040 pads (datasheet sec 2.19.6) so
@ gpio_init does not need to CLR ISO before driving the pin.  The full M2
@ surface for gpio_init is:
@   1. PADS_BANK0[pin] CLR = OD       (clear output-disable so SIO can drive)
@   2. IO_BANK0[pin]  CTRL = FUNCSEL  (5 = SIO)
@   3. SIO_GPIO_OE_CLR  = 1 << pin    (start as input)
@   4. SIO_GPIO_OUT_CLR = 1 << pin    (output value defaults low)
@
@ Pico 1 / RP2040 board LED is GP25 (same pin number as Pico 2 / RP2350).
@ =============================================================================

    .include "rp2040.inc"

    .syntax unified
    .cpu    cortex-m0plus
    .thumb

@ ============================================================================
@ Public API - drive / configure
@ ============================================================================

@ ---------------------------------------------------------------------------
@ gpio_set_function(pin, func)
@   r0 = pin (0..29), r1 = func (0..31)
@ Writes IO_BANK0_BASE + 4 + pin*8 = func.
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_function, "ax"
    .thumb_func
    .global  gpio_set_function
gpio_set_function:
    lsls    r2, r0, #3                     @ r2 = pin * 8
    adds    r2, #IO_BANK0_GPIO_CTRL_OFFS   @ r2 = 4 + pin*8
    ldr     r3, =IO_BANK0_BASE
    str     r1, [r3, r2]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_set_dir(pin, out_bool)
@   r0 = pin, r1 = 0 (input) | nonzero (output)
@   Selects between SIO_GPIO_OE_SET and SIO_GPIO_OE_CLR.
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_dir, "ax"
    .thumb_func
    .global  gpio_set_dir
gpio_set_dir:
    movs    r2, #1
    lsls    r2, r0                         @ r2 = 1 << pin
    cmp     r1, #0
    beq     1f
    ldr     r3, =SIO_BASE + SIO_GPIO_OE_SET
    str     r2, [r3]
    bx      lr
1:  ldr     r3, =SIO_BASE + SIO_GPIO_OE_CLR
    str     r2, [r3]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_put(pin, value_bool)
@ ---------------------------------------------------------------------------
    .section .text.gpio_put, "ax"
    .thumb_func
    .global  gpio_put
gpio_put:
    movs    r2, #1
    lsls    r2, r0
    cmp     r1, #0
    beq     1f
    ldr     r3, =SIO_BASE + SIO_GPIO_OUT_SET
    str     r2, [r3]
    bx      lr
1:  ldr     r3, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r2, [r3]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_get(pin) -> r0 (0 or 1)
@ ---------------------------------------------------------------------------
    .section .text.gpio_get, "ax"
    .thumb_func
    .global  gpio_get
gpio_get:
    ldr     r3, =SIO_BASE + SIO_GPIO_IN
    ldr     r1, [r3]
    lsrs    r1, r0
    movs    r0, #1
    ands    r0, r1
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_toggle(pin)
@ ---------------------------------------------------------------------------
    .section .text.gpio_toggle, "ax"
    .thumb_func
    .global  gpio_toggle
gpio_toggle:
    movs    r2, #1
    lsls    r2, r0
    ldr     r3, =SIO_BASE + SIO_GPIO_OUT_XOR
    str     r2, [r3]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_init(pin)
@   pad: clear OD (atomic CLR)
@   mux: SIO  (plain CTRL store)
@   SIO: OUT=0 (OUT_CLR), OE=0 (OE_CLR)
@ ---------------------------------------------------------------------------
    .section .text.gpio_init, "ax"
    .thumb_func
    .global  gpio_init
gpio_init:
    push    {r4, lr}
    mov     r4, r0                         @ keep pin in r4

    @ 1. PADS_BANK0[pin] CLR = OD
    lsls    r1, r4, #2                     @ r1 = pin * 4
    adds    r1, #PADS_BANK0_GPIO_OFFS
    ldr     r2, =PADS_BANK0_BASE + ATOMIC_CLR
    movs    r3, #PADS_OD
    str     r3, [r2, r1]

    @ 2. IO_BANK0[pin] CTRL = SIO
    lsls    r1, r4, #3                     @ r1 = pin * 8
    adds    r1, #IO_BANK0_GPIO_CTRL_OFFS
    ldr     r2, =IO_BANK0_BASE
    movs    r3, #GPIO_FUNC_SIO
    str     r3, [r2, r1]

    @ 3. SIO_GPIO_OUT_CLR = 1 << pin
    movs    r3, #1
    lsls    r3, r4
    ldr     r2, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r3, [r2]
    @ 4. SIO_GPIO_OE_CLR  = 1 << pin
    ldr     r2, =SIO_BASE + SIO_GPIO_OE_CLR
    str     r3, [r2]

    pop     {r4, pc}

@ ============================================================================
@ Compat shims for the M2 boot path: same names as the RP2350 driver so a
@ shared main.S can call them.  RP2040's Pico LED is on GP25 (same pin as
@ Pico 2's onboard LED), so gpio_led_init/toggle work identically.
@ ============================================================================

    .equ LED_PIN, 25

    .section .text.gpio_led_init, "ax"
    .thumb_func
    .global  gpio_led_init
gpio_led_init:
    @ ---- 1. PADS_BANK0[25] CLR = OD --------------------------------------
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (LED_PIN * 4)
    movs    r1, #PADS_OD
    str     r1, [r0]

    @ ---- 2. IO_BANK0[25] CTRL = SIO --------------------------------------
    ldr     r0, =IO_BANK0_BASE + 4 + (LED_PIN * 8)
    movs    r1, #GPIO_FUNC_SIO
    str     r1, [r0]

    @ ---- 3 + 4. SIO drive low, then enable output ------------------------
    movs    r2, #1
    lsls    r2, #LED_PIN                   @ r2 = 1 << 25

    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r2, [r0]
    ldr     r0, =SIO_BASE + SIO_GPIO_OE_SET
    str     r2, [r0]

    bx      lr

    .section .text.gpio_led_toggle, "ax"
    .thumb_func
    .global  gpio_led_toggle
gpio_led_toggle:
    movs    r1, #1
    lsls    r1, #LED_PIN
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_XOR
    str     r1, [r0]
    bx      lr
