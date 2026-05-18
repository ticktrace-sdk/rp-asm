@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/spi_loopback_demo.S - SPI0 internal loopback (M4-G).
@
@ Brings up SPI0 in master mode at 1 MHz with LBM=1 so the TX serialiser is
@ wired internally back to the RX serialiser.  Pushes 256 bytes of a known
@ ramp through full-duplex (write_read_blocking) and verifies the RX buffer
@ matches byte-for-byte.  Reports PASS or "FAIL N" via UART0.
@
@ Build:    make build/spi_loopback_demo.uf2
@ Verify:   115200 8N1 on GP0; expect
@             ticktrace M4-G: SPI0 loopback demo
@             PASS
@           (or "FAIL <count>" with the number of mismatches)
@
@ This demo doesn't bring up the PLL chain - we run at clk_peri = 12 MHz
@ post-bootrom and pick a 1 MHz SPI baud (CPSDVSR=2, SCR=5 -> ~1.0 MHz).
@ Full-duplex through the loopback path doesn't need real wiring; we get
@ deterministic single-image self-test.
@ =============================================================================

    .include "rp2350.inc"
    .include "spi.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ XFER_LEN, 256

@ ----- ROdata: ramp source 0..255 -------------------------------------------
    .section .rodata.spi_loop_src, "a"
    .align   2
spi_loop_src:
    .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    .byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    .byte 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
    .byte 48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
    .byte 64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79
    .byte 80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95
    .byte 96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111
    .byte 112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127
    .byte 128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143
    .byte 144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159
    .byte 160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175
    .byte 176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191
    .byte 192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207
    .byte 208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223
    .byte 224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239
    .byte 240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255

@ ----- Banners --------------------------------------------------------------
    .section .rodata.spi_loop_banners, "a"
banner_intro:
    .asciz "ticktrace M4-G: SPI0 loopback demo\r\n"
banner_pass:
    .asciz "PASS\r\n"
banner_fail:
    .asciz "FAIL "
banner_nl:
    .asciz "\r\n"

@ ----- BSS: receive buffer --------------------------------------------------
    .section .bss.spi_loop_dst, "aw", %nobits
    .align   2
spi_loop_dst:
    .space   XFER_LEN

@ ----- Main -----------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, r5, r6, lr}

    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    @ Bring up SPI0 at 1 MHz; sets CR0=8-bit Motorola, CR1 = master + SSE.
    movs    r0, #0
    movw    r1, #(1000000 & 0xFFFF)
    movt    r1, #(1000000 >> 16)
    bl      spi_init

    @ Enable internal loopback (with the SSE clear/restore the driver does).
    movs    r0, #0
    movs    r1, #1
    bl      spi_set_loopback

    @ Full-duplex transfer.
    movs    r0, #0
    ldr     r1, =spi_loop_src
    ldr     r2, =spi_loop_dst
    movs    r3, #XFER_LEN
    bl      spi_write_read_blocking

    @ Verify byte-for-byte equality.
    ldr     r4, =spi_loop_src
    ldr     r5, =spi_loop_dst
    movs    r6, #0                          @ mismatch count
    movs    r0, #0                          @ index
.Lcheck:
    ldrb    r1, [r4, r0]
    ldrb    r2, [r5, r0]
    cmp     r1, r2
    beq     1f
    adds    r6, #1
1:  adds    r0, #1
    cmp     r0, #XFER_LEN
    blo     .Lcheck

    cbz     r6, .Lpass
    @ Print "FAIL <r6>\r\n"
    ldr     r0, =banner_fail
    bl      uart0_puts
    mov     r0, r6
    bl      print_decimal
    ldr     r0, =banner_nl
    bl      uart0_puts
    b       .Lhalt

.Lpass:
    ldr     r0, =banner_pass
    bl      uart0_puts

.Lhalt:
    @ Slow blink to show liveness; ~50 ms half-period at 12 MHz.
2:  bl      gpio_led_toggle
    ldr     r0, =600000
3:  subs    r0, #1
    bne     3b
    b       2b

@ ----------------------------------------------------------------------------
@ print_decimal(uint32_t x) - emit `x` as decimal via uart0_putc.
@ Recursive divide-by-10; ~12 instructions.
@ ----------------------------------------------------------------------------
    .section .text.print_decimal, "ax"
    .thumb_func
    .global  print_decimal
print_decimal:
    push    {r4, lr}
    movs    r1, #10
    udiv    r2, r0, r1
    mls     r4, r2, r1, r0
    cbz     r2, 1f
    mov     r0, r2
    bl      print_decimal
1:  add     r0, r4, #'0'
    bl      uart0_putc
    pop     {r4, pc}
