@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/pwm_irq_demo.S - slice 0 wrap IRQ toggles GP25 (on-board LED).
@
@ Goal: prove the PWM_IRQ_WRAP_0 plumbing end-to-end without depending on
@ Agent B's NVIC helpers.  We program NVIC_ISER0 directly.
@
@ Vector table strategy:
@   The shipped src/startup.S exposes only 16 system vectors; the PWM wrap
@   IRQ lives at NVIC line 8 (vector index 16+8 = 24, byte offset 0x60).
@   We can't extend startup.S's table, so we build a private 64-entry
@   vector table in this example, copy SP/Reset_Handler/system entries
@   from the original table, install our PWM ISR at slot 24, then re-point
@   VTOR at our table.
@
@ Wire-up:
@   1. Bring up clocks + GPIO + UART (banner once).
@   2. Configure slice 0 to wrap at TOP=0xFFFF with DIV.int = 100
@        wrap rate = 150e6 / (100 * 65536) ~= 22.9 Hz   -> ~22 Hz LED toggle
@   3. Enable INTE for slice 0; enable NVIC IRQ 8.
@   4. ISR: ack INTR, toggle GP25 via SIO_GPIO_OUT_XOR.
@   5. main loops on WFI - all toggling driven by the ISR.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/pwm.S"

    @ ---- IRQ demo constants ----------------------------------------------
    .equ IRQ_SLICE,         0
    .equ IRQ_TOP_HIGH,      0xFFFF
    .equ IRQ_DIV_INT,       100         @ -> ~22.9 Hz wrap

    @ NVIC: external IRQ 8 = PWM_IRQ_WRAP_0
    .equ NVIC_ISER0,        0xE000E100
    .equ NVIC_ICPR0,        0xE000E280

    @ Custom vector table lives in .data so we can install our ISR at the
    @ PWM_IRQ_WRAP_0 slot.  64 entries is plenty for any RP2350 IRQ line.
    .equ NUM_VECTORS,       64
    .equ PWM_VECTOR_INDEX,  (16 + PWM_IRQ_WRAP_0)   @ 24

    .section .rodata.banner_pwm_irq, "a"
banner:
    .asciz "pwm irq demo: slice 0 wrap IRQ -> GP25 toggle\r\n"

    @ ---- Custom vector table (ALIGN(128) = 0x80) -------------------------
    @ ARMv8-M VTOR requires the table to be aligned to the next power of
    @ two >= (NumExceptions * 4).  64 * 4 = 256 -> align(256).
    .section .bss.pwm_irq_vectors, "aw", %nobits
    .align 8
pwm_irq_vectors:
    .space NUM_VECTORS * 4

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clock tree -------------------------------------------------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- LED on GP25 (target of the toggle) ------------------------------
    bl      gpio_led_init

    @ ---- UART banner -----------------------------------------------------
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner
    bl      uart0_puts

    @ ---- Build runtime vector table --------------------------------------
    @ Step 1: copy first 16 entries from the build-time _vectors so SP /
    @ Reset_Handler / hard-fault stubs all keep working through VTOR.
    ldr     r0, =_vectors
    ldr     r1, =pwm_irq_vectors
    movs    r2, #16             @ words to copy
1:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    subs    r2, #1
    bne     1b

    @ Step 2: install pwm_wrap_isr at slot PWM_VECTOR_INDEX (24)
    ldr     r0, =pwm_irq_vectors
    ldr     r1, =pwm_wrap_isr + 1       @ Thumb bit
    str     r1, [r0, #(PWM_VECTOR_INDEX * 4)]

    @ Step 3: VTOR <- pwm_irq_vectors
    ldr     r0, =SCB_VTOR
    ldr     r1, =pwm_irq_vectors
    str     r1, [r0]

    @ ---- PWM bring-up ----------------------------------------------------
    bl      pwm_init

    movs    r0, #IRQ_SLICE
    movs    r1, #IRQ_DIV_INT
    bl      pwm_set_clkdiv_int

    movs    r0, #IRQ_SLICE
    movw    r1, #IRQ_TOP_HIGH
    bl      pwm_set_wrap

    @ Clear any pending wrap IRQ before we enable
    movs    r0, #IRQ_SLICE
    bl      pwm_acknowledge_irq

    @ Enable INTE for slice 0
    movs    r0, #IRQ_SLICE
    movs    r1, #1
    bl      pwm_irq_enable

    @ ---- NVIC: enable IRQ line 8 -----------------------------------------
    movs    r1, #1
    lsls    r1, #PWM_IRQ_WRAP_0         @ bit 8
    ldr     r0, =NVIC_ISER0
    str     r1, [r0]

    @ ---- Start the slice -------------------------------------------------
    movs    r0, #IRQ_SLICE
    movs    r1, #1
    bl      pwm_set_enabled

.Lwfi_loop:
    wfi
    b       .Lwfi_loop

@ ----------------------------------------------------------------------------
@ pwm_wrap_isr - PWM_IRQ_WRAP_0 handler.
@ Acks the slice-0 wrap, then toggles GP25 via SIO_GPIO_OUT_XOR.
@ ----------------------------------------------------------------------------
    .section .text.pwm_wrap_isr, "ax"
    .thumb_func
    .global  pwm_wrap_isr
pwm_wrap_isr:
    push    {r4, lr}

    @ Acknowledge wrap IRQ for slice 0 (write 1<<0 to PWM_INTR)
    movs    r1, #1
    ldr     r0, =PWM_BASE + PWM_INTR
    str     r1, [r0]

    @ Toggle GP25
    movs    r1, #1
    lsls    r1, #25                     @ 1 << 25
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_XOR
    str     r1, [r0]

    pop     {r4, pc}
