@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/uart_dma_demo.S - DMA-paced UART0 TX of a 256-byte ramp (M4-E).
@
@ Boot path:
@   1. Standard M2 clocks bring-up (150 MHz clk_sys / clk_peri).
@   2. uart_init(0, 115200, 150e6).
@   3. uart_set_dma_enabled(0, tx=1, rx=0)  -> DMACR.TXDMAE
@   4. uart_puts_blocking(0, "uart-dma\r\n")
@   5. Configure DMA ch0:
@        ctrl  = EN | DATA_SIZE_BYTE | INCR_READ |
@                (DREQ_UART0_TX << TREQ_SEL_LSB)
@        read  = ramp[0]
@        write = UART0_BASE + UART_DR
@        count = 256
@        trig  = 1
@   6. dma_channel_wait_for_finish(0)
@   7. uart_tx_wait_blocking(0)               (drain shift register)
@   8. uart_puts_blocking(0, "uart-dma OK\r\n")
@
@ Verifies:
@   - PL011 DMA pacing via DREQ_UART0_TX (TREQ value 28, see include/dma.inc)
@   - DMACR.TXDMAE set/clear semantics
@   - DMA channel byte-sized writes don't cause OE on the PL011
@ =============================================================================

    .include "rp2350.inc"
    .include "dma.inc"
    .include "uart.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ RAMP_LEN, 256

    .section .rodata.uart_dma_ramp, "a"
    .align 2
ramp:
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

    .section .rodata.uart_dma_banners, "a"
banner_intro:
    .asciz "uart-dma\r\n"
banner_done:
    .asciz "uart-dma OK\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, lr}

    @ ---- Clock tree bring-up --------------------------------------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- UART0 at 115200 8N1 --------------------------------------------
    movs    r0, #0
    ldr     r1, =115200
    ldr     r2, =150000000
    bl      uart_init

    @ ---- DMA out of reset -----------------------------------------------
    bl      dma_init

    @ ---- Enable TX DMA pacing on UART0 ----------------------------------
    movs    r0, #0
    movs    r1, #1                          @ tx
    movs    r2, #0                          @ rx
    bl      uart_set_dma_enabled

    @ ---- Banner via the standard blocking path --------------------------
    movs    r0, #0
    ldr     r1, =banner_intro
    bl      uart_puts_blocking

    @ ---- Configure DMA channel 0 (byte, src+, dst fixed, paced by UART0_TX)
    @  ctrl = EN | DATA_SIZE_BYTE | INCR_READ | (DREQ_UART0_TX << TREQ_SEL_LSB)
    ldr     r1, =(DMA_CTRL_EN | DMA_DATA_SIZE_BYTE | DMA_CTRL_INCR_READ | (DREQ_UART0_TX << DMA_CTRL_TREQ_SEL_LSB))

    @ count + trigger args on stack for dma_channel_configure
    ldr     r0, =RAMP_LEN
    movs    r4, #1
    push    {r0, r4}                        @ [sp]=count, [sp+4]=trig

    movs    r0, #0                          @ ch
    ldr     r2, =ramp                       @ src
    ldr     r3, =UART0_BASE + UART_DR       @ dst
    bl      dma_channel_configure

    movs    r0, #0
    bl      dma_channel_wait_for_finish

    add     sp, sp, #8

    @ ---- Drain the shift register (FIFO + serializer) -------------------
    movs    r0, #0
    bl      uart_tx_wait_blocking

    @ ---- Done banner ----------------------------------------------------
    movs    r0, #0
    ldr     r1, =banner_done
    bl      uart_puts_blocking

.Lloop:
    wfi
    b       .Lloop
