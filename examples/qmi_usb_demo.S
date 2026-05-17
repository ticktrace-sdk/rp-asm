@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/qmi_usb_demo.S - measure XIP flash-read speed before/after QMI tuning.
@
@ Cold-cache reads a 16 KiB chunk of rodata from XIP to SRAM, then reports
@ DWT cycle counts at the default QMI CLKDIV vs CLKDIV = 2 (~75 MHz SCK
@ at clk_sys = 150 MHz, ~6x faster than the bootrom default of 12).
@
@ Each iteration:
@   read default CLKDIV value          (so we know what we started from)
@   qmi_flush_cache + DWT-time the 16 KiB copy             -> cold_default
@   qmi_set_clkdiv(2)                  (flushes cache as a side effect)
@   DWT-time the same copy             -> cold_fast
@   restore CLKDIV to the recorded default for the next iteration
@   prints "qmi default=D cold_default=N cold_fast=M ratio=X"
@
@ Only meaningful for the flash UF2 - SRAM build has no XIP path to tune.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "trace.inc"
    .include "usb.inc"

    .equ COPY_BYTES,    16384

    .equ QMI_BASE,      0x400D0000
    .equ QMI_M0_TIMING, 0x0C
    .equ FAST_CLKDIV,   2

    .section .bss.qmi_dst, "aw", %nobits
    .align   2
xip_dst:
    .space   COPY_BYTES

    @ 16 KiB of rodata pattern in flash, bigger than the 16 KiB XIP cache
    @ (after our other code) -> forces cold reads.  Pattern is "ABCD"
    @ repeating so the linker doesn't dedup or zero-eliminate.
    .section .rodata.qmi_src, "a"
    .align   2
xip_src:
    .rept (COPY_BYTES / 4)
    .word 0x44434241
    .endr

    .section .data.qmi_state, "aw"
    .align   2
iter_count: .word 0

    .section .rodata.qmi_usb, "a"
banner_uart:        .asciz "rp-asm M7 - QMI flash-read speed before/after CLKDIV tune\r\n"
prefix_iter:        .asciz "iter="
mid_default:        .asciz " default_clkdiv="
mid_cold_default:   .asciz " cold_default="
mid_cold_fast:      .asciz " cold_fast="
mid_ratio:          .asciz " speedup_x100="
suffix_crlf:        .asciz "\r\n"

@ ----------------------------------------------------------------------------
@ _put_uint_decimal
@ ----------------------------------------------------------------------------
    .section .text._put_uint_decimal, "ax"
    .thumb_func
_put_uint_decimal:
    push    {r4, r5, r6, lr}
    sub     sp, sp, #12
    mov     r4, sp
    adds    r4, #11
    movs    r5, #0
    strb    r5, [r4]
    movs    r6, #10
    cbnz    r0, 1f
    subs    r4, #1
    movs    r5, #'0'
    strb    r5, [r4]
    b       2f
1:  udiv    r2, r0, r6
    mls     r3, r2, r6, r0
    adds    r3, #'0'
    subs    r4, #1
    strb    r3, [r4]
    mov     r0, r2
    cmp     r0, #0
    bne     1b
2:  mov     r0, r4
    bl      cdc_puts
    add     sp, sp, #12
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ _memcpy32(dst, src, words) - word-stride memcpy
@ ----------------------------------------------------------------------------
    .section .text._memcpy32, "ax"
    .thumb_func
_memcpy32:
    cbz     r2, 9f
1:  ldr     r3, [r1], #4
    str     r3, [r0], #4
    subs    r2, #1
    bne     1b
9:  bx      lr

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
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

    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner_uart
    bl      uart0_puts

    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    bl      dwt_init

.Lloop:
    @ ---- Snapshot the bootrom-default CLKDIV ----------------------------
    ldr     r0, =QMI_BASE
    ldr     r4, [r0, #QMI_M0_TIMING]
    and     r4, r4, #0xFF                         @ r4 = default CLKDIV

    @ ---- Cold-cache copy at default CLKDIV ------------------------------
    bl      qmi_flush_cache
    bl      dwt_cycles_read
    mov     r5, r0                                @ t0
    ldr     r0, =xip_dst
    ldr     r1, =xip_src
    ldr     r2, =(COPY_BYTES / 4)
    bl      _memcpy32
    bl      dwt_cycles_read
    sub     r5, r0, r5                            @ r5 = cold_default cycles

    @ ---- Switch to fast CLKDIV (flushes cache as a side effect) --------
    movs    r0, #FAST_CLKDIV
    bl      qmi_set_clkdiv

    @ ---- Cold-cache copy at fast CLKDIV --------------------------------
    bl      dwt_cycles_read
    mov     r6, r0
    ldr     r0, =xip_dst
    ldr     r1, =xip_src
    ldr     r2, =(COPY_BYTES / 4)
    bl      _memcpy32
    bl      dwt_cycles_read
    sub     r6, r0, r6                            @ r6 = cold_fast cycles

    @ ---- Restore default CLKDIV for the next iteration ------------------
    mov     r0, r4
    bl      qmi_set_clkdiv

    @ ---- Print results ---------------------------------------------------
    ldr     r0, =prefix_iter
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      _put_uint_decimal

    ldr     r0, =mid_default
    bl      cdc_puts
    mov     r0, r4
    bl      _put_uint_decimal

    ldr     r0, =mid_cold_default
    bl      cdc_puts
    mov     r0, r5
    bl      _put_uint_decimal

    ldr     r0, =mid_cold_fast
    bl      cdc_puts
    mov     r0, r6
    bl      _put_uint_decimal

    @ speedup_x100 = (cold_default * 100) / cold_fast
    movw    r0, #100
    muls    r0, r0, r5
    udiv    r0, r0, r6
    ldr     r1, =mid_ratio
    mov     r7, r0
    mov     r0, r1
    bl      cdc_puts
    mov     r0, r7
    bl      _put_uint_decimal

    ldr     r0, =suffix_crlf
    bl      cdc_puts

    bl      gpio_led_toggle

    @ ~1 s pause
    ldr     r0, =50000000
3:  subs    r0, #1
    bne     3b
    b       .Lloop

    .include "src/nvic.S"
