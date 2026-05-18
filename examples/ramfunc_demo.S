@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ ramfunc_demo.S - cycle-determinism: flash XIP vs SRAM (.ramfunc)
@
@ Defines the same busy-loop body twice:
@   busy_xip   lives in default .text  -- flash on the flash build, SRAM on
@                                         the SRAM build
@   busy_ram   lives in .ramfunc       -- always SRAM after startup copies it,
@                                         on both builds
@
@ At runtime, calls each function REPEATS times. Each call's cycle count is
@ captured via DWT; we track min and max. Then we print:
@
@     xip   busy: min=NNNN max=NNNN
@     ram   busy: min=NNNN max=NNNN
@
@ On the *flash* build on real hardware, busy_xip should show min<max because
@ of XIP cache misses; busy_ram should be dead-flat.
@ On the *SRAM* build, both should be flat (whole image lives in SRAM).
@
@ Build:
@     make build/ramfunc_demo_flash.uf2     # the interesting one for hardware
@     make build/ramfunc_demo.uf2           # SRAM variant, both paths flat
@ Flash with BOOTSEL, then read UART0 TX (GP0) at 115200 8N1.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ INNER_ITERS,   1000
    .equ REPEATS,       64

@ ---------------------------------------------------------------------------
@ busy_xip - identical body to busy_ram, but linked in .text.
@ On flash builds this runs XIP from QSPI; cache-miss variance is visible.
@ ---------------------------------------------------------------------------
    .section .text.busy_xip, "ax"
    .thumb_func
    .global  busy_xip
busy_xip:
    push    {r4, lr}
    ldr     r4, =INNER_ITERS
1:  subs    r4, #1
    bne     1b
    pop     {r4, pc}

@ ---------------------------------------------------------------------------
@ busy_ram - identical body to busy_xip, but linked in .ramfunc.
@ Startup copies this from flash (LMA) to SRAM (VMA) before main runs.
@ ---------------------------------------------------------------------------
    .section .ramfunc.busy_ram, "ax"
    .thumb_func
    .global  busy_ram
busy_ram:
    push    {r4, lr}
    ldr     r4, =INNER_ITERS
1:  subs    r4, #1
    bne     1b
    pop     {r4, pc}

@ ===========================================================================
@ Data
@ ===========================================================================
    .section .rodata.ramfunc_demo, "a"
banner:
    .asciz "ramfunc demo: 1000-iter busy loop, 64 trials each path\r\n"
xip_label:
    .asciz "xip   busy: min="
ram_label:
    .asciz "ram   busy: min="
max_label:
    .asciz " max="
nl:
    .asciz "\r\n"
hex_digits:
    .ascii "0123456789abcdef"

    .section .bss.ramfunc_demo, "aw", %nobits
xip_min:    .space 4
xip_max:    .space 4
ram_min:    .space 4
ram_max:    .space 4

@ ===========================================================================
@ Main
@ ===========================================================================
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- standard clock + UART bring-up ----
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    bl      dwt_init

    ldr     r0, =banner
    bl      uart0_puts

    @ ---- measure busy_xip over REPEATS calls ----
    ldr     r0, =xip_min
    ldr     r1, =0xFFFFFFFF
    str     r1, [r0]
    ldr     r0, =xip_max
    movs    r1, #0
    str     r1, [r0]

    movs    r5, #REPEATS
.Lxip_loop:
    bl      dwt_cycles_read
    mov     r4, r0
    bl      busy_xip
    mov     r0, r4
    bl      dwt_cycles_since        @ r0 = delta cycles for this call

    @ Update min in xip_min
    ldr     r1, =xip_min
    ldr     r2, [r1]
    cmp     r0, r2
    bhs     1f
    str     r0, [r1]
1:
    @ Update max in xip_max
    ldr     r1, =xip_max
    ldr     r2, [r1]
    cmp     r0, r2
    bls     2f
    str     r0, [r1]
2:
    subs    r5, #1
    bne     .Lxip_loop

    @ ---- measure busy_ram over REPEATS calls ----
    ldr     r0, =ram_min
    ldr     r1, =0xFFFFFFFF
    str     r1, [r0]
    ldr     r0, =ram_max
    movs    r1, #0
    str     r1, [r0]

    movs    r5, #REPEATS
.Lram_loop:
    bl      dwt_cycles_read
    mov     r4, r0
    bl      busy_ram
    mov     r0, r4
    bl      dwt_cycles_since

    ldr     r1, =ram_min
    ldr     r2, [r1]
    cmp     r0, r2
    bhs     1f
    str     r0, [r1]
1:
    ldr     r1, =ram_max
    ldr     r2, [r1]
    cmp     r0, r2
    bls     2f
    str     r0, [r1]
2:
    subs    r5, #1
    bne     .Lram_loop

    @ ---- print the four numbers ----
    ldr     r0, =xip_label
    bl      uart0_puts
    ldr     r0, =xip_min
    ldr     r0, [r0]
    bl      print_u32_hex
    ldr     r0, =max_label
    bl      uart0_puts
    ldr     r0, =xip_max
    ldr     r0, [r0]
    bl      print_u32_hex
    ldr     r0, =nl
    bl      uart0_puts

    ldr     r0, =ram_label
    bl      uart0_puts
    ldr     r0, =ram_min
    ldr     r0, [r0]
    bl      print_u32_hex
    ldr     r0, =max_label
    bl      uart0_puts
    ldr     r0, =ram_max
    ldr     r0, [r0]
    bl      print_u32_hex
    ldr     r0, =nl
    bl      uart0_puts

    @ ---- blink forever so you can see the chip is alive ----
.Lhalt:
    bl      gpio_led_toggle
    ldr     r0, =12500000
1:  subs    r0, #1
    bne     1b
    b       .Lhalt

@ ---------------------------------------------------------------------------
@ print_u32_hex(r0=value) - 8 hex digits over UART0
@ ---------------------------------------------------------------------------
    .section .text.print_u32_hex, "ax"
    .thumb_func
print_u32_hex:
    push    {r4, r5, r6, lr}
    mov     r4, r0
    ldr     r5, =hex_digits
    movs    r6, #28
1:  mov     r0, r4
    lsrs    r0, r6
    movs    r1, #0xF
    ands    r0, r1
    ldrb    r0, [r5, r0]
    bl      uart0_putc
    subs    r6, #4
    bge     1b
    pop     {r4, r5, r6, pc}
