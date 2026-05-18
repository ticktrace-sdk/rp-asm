@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/systick_demo.S - 1 ms SysTick + uptime banner.
@
@ Configures SysTick for a 1 ms tick (RVR = 150_000 - 1 at clk_sys = 150 MHz,
@ CLKSOURCE = 1 = processor clock).  The ISR increments a 32-bit counter
@ in SRAM (`uptime_ms`); main reads it and prints "uptime <N> ms\r\n" once
@ per second using delay_ms.
@
@ Build:    make build/systick_demo.uf2
@
@ The expected uptime drift is < 1 part in 10^4 (PLL_SYS jitter at 150 MHz).
@ ============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ SYSTICK_PERIOD_MINUS1, (150000 - 1)    @ 1 ms @ 150 MHz processor clock

    @ Use .data so the value is loaded as part of the UF2 image and starts at
    @ zero on a cold boot.  .bss is NOLOAD in the linker script and we have
    @ no C-style runtime that zeroes it.
    .section .data.uptime, "aw"
    .align 2
    .global uptime_ms
uptime_ms:
    .word 0

    .section .rodata.banner_systick, "a"
banner_systick:
    .asciz "ticktrace M3-B - SysTick 1 ms\r\n"
prefix_msg:
    .asciz "uptime "
suffix_msg:
    .asciz " ms\r\n"

@ ---------------------------------------------------------------------------
@ systick_isr - bumps uptime_ms by 1 each tick.
@ Vector index 15 in the existing _vectors table is _halt; we patch it at
@ runtime by writing into the in-RAM vector table (slot 15 * 4 = 0x3c).
@ ---------------------------------------------------------------------------
    .section .text.systick_isr, "ax"
    .thumb_func
    .global  systick_isr
systick_isr:
    ldr     r0, =uptime_ms
    ldr     r1, [r0]
    adds    r1, r1, #1
    str     r1, [r0]
    bx      lr

@ ---------------------------------------------------------------------------
@ uart0_put_u32 - print r0 as decimal with no leading zeros.
@ Clobbers: r0-r4, lr.
@
@ Iterative "divide by 10" using the M33's hardware UDIV.  Pushes digits to
@ a temp buffer on the stack (max 10 chars for a 32-bit decimal).
@ ---------------------------------------------------------------------------
    .section .text.uart0_put_u32, "ax"
    .thumb_func
    .global  uart0_put_u32
uart0_put_u32:
    push    {r4-r6, lr}
    @ Special-case zero so we always print at least "0".
    cmp     r0, #0
    bne     1f
    movs    r0, #'0'
    bl      uart0_putc
    pop     {r4-r6, pc}

1:  @ Build digits in a 12-byte stack buffer (sp..sp+11).  We push 3 zero
    @ words then write bytes into it, in reverse.
    movs    r4, #0
    push    {r4}
    push    {r4}
    push    {r4}
    mov     r5, sp                          @ buffer base
    add     r6, r5, #12                     @ ptr (one past end)
    movw    r4, #10
2:  udiv    r1, r0, r4                      @ q = r0 / 10
    mls     r2, r1, r4, r0                  @ rem = r0 - q*10
    add     r2, r2, #'0'
    sub     r6, r6, #1
    strb    r2, [r6]                        @ *--ptr = '0'+rem
    mov     r0, r1                          @ r0 = q
    cmp     r0, #0
    bne     2b

    @ Print [r6, sp+12)
    add     r4, r5, #12
3:  cmp     r6, r4
    beq     4f
    ldrb    r0, [r6], #1
    bl      uart0_putc
    b       3b
4:  add     sp, sp, #12
    pop     {r4-r6, pc}

@ ---------------------------------------------------------------------------
@ main
@ ---------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    bl      timer_init                      @ delay_ms uses TIMER0
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    ldr     r0, =banner_systick
    bl      uart0_puts

    @ ---- Install the SysTick handler at vector index 15 -------------------
    @ SysTick is a system exception (not an external IRQ), so we cannot
    @ reuse nvic_install_handler (which assumes the +16 offset).  We patch
    @ the vector word directly.
    ldr     r0, =SCB_VTOR
    ldr     r0, [r0]
    add     r0, r0, #(15 * 4)               @ slot 15 = SysTick
    ldr     r1, =systick_isr
    orr     r1, r1, #1                      @ Thumb bit
    str     r1, [r0]

    @ ---- Start SysTick: 1 ms period --------------------------------------
    ldr     r0, =SYSTICK_PERIOD_MINUS1
    bl      systick_start_periodic

.Lloop:
    bl      gpio_led_toggle

    ldr     r0, =prefix_msg
    bl      uart0_puts
    ldr     r0, =uptime_ms
    ldr     r0, [r0]
    bl      uart0_put_u32
    ldr     r0, =suffix_msg
    bl      uart0_puts

    movw    r0, #1000
    bl      delay_ms
    b       .Lloop

@ ---- Bundle the M3-B driver objects into this image -----------------------
    .include "src/timer.S"
    .include "src/systick.S"
    .include "src/nvic.S"
