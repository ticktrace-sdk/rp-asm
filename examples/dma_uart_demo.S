@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/dma_uart_demo.S - DMA-paced UART TX demo (M3-C).
@
@ Configures DMA channel 0 to copy a banner string from .rodata, byte-by-byte,
@ into UART0_DR, paced by DREQ_UART0_TX.  Demonstrates DREQ-paced peripheral
@ writes - the DMA channel only advances when UART0 says "TX FIFO has room".
@
@ Build:    make examples/dma_uart_demo.uf2  ->  build/dma_uart_demo.uf2
@ Verify:   115200 8N1 on GP0; expect to see
@             ticktrace M3-C: DMA->UART demo
@             ...followed by a DMA-paced banner...
@             DMA->UART done
@           with the middle banner emitted entirely by DMA (CPU is parked in
@           dma_channel_wait_for_finish for the duration).
@ =============================================================================

    .include "rp2350.inc"
    .include "dma.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ---- The DMA-emitted banner.  Byte-sized writes; DREQ-paced. ----------------
    .section .rodata.dma_uart_banner, "a"
    .align   2
banner_dma_payload:
    .ascii "  [DMA -> UART0_DR via DREQ_UART0_TX, "
    .ascii "byte-paced]\r\n"
banner_dma_payload_end:
    .equ   BANNER_DMA_LEN, banner_dma_payload_end - banner_dma_payload

    .section .rodata.banners, "a"
banner_intro:
    .asciz "ticktrace M3-C: DMA->UART demo\r\n"
banner_done:
    .asciz "DMA->UART done\r\n"

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, lr}

    @ ---- Boot (UART at bootrom-default 12 MHz clk_peri) ------------------
    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    bl      dma_init

    @ ---- Configure ch0 = byte-sized, src+, dst fixed @ UART0_DR, paced by
    @      DREQ_UART0_TX.  CHAIN_TO defaults to 0 (= self = no chain).
    @
    @ CTRL = EN | DATA_SIZE_BYTE | INCR_READ |
    @        (DREQ_UART0_TX << TREQ_SEL_LSB)
    ldr     r1, =(DMA_CTRL_EN | DMA_DATA_SIZE_BYTE | DMA_CTRL_INCR_READ | (DREQ_UART0_TX << DMA_CTRL_TREQ_SEL_LSB))

    @ count + trigger args on stack
    ldr     r0, =BANNER_DMA_LEN
    movs    r4, #1
    push    {r0, r4}                       @ [sp]=count, [sp+4]=trig

    movs    r0, #0                         @ ch
    ldr     r2, =banner_dma_payload        @ src
    ldr     r3, =UART0_BASE + UART_DR      @ dst (fixed)
    bl      dma_channel_configure

    @ Wait for the DMA-paced TX to drain
    movs    r0, #0
    bl      dma_channel_wait_for_finish

    add     sp, sp, #8

    @ The DMA hand-off completed but the PL011 may still have queued bytes
    @ in the TX FIFO.  Spin on UART_FR.BUSY before printing the trailer so
    @ the two banners stay in order on the wire.
    ldr     r0, =UART0_BASE + UART_FR
1:  ldr     r1, [r0]
    movs    r2, #UART_FR_BUSY
    tst     r1, r2
    bne     1b

    ldr     r0, =banner_done
    bl      uart0_puts

    @ Park.
.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =3000000
2:  subs    r0, #1
    bne     2b
    b       .Lloop
