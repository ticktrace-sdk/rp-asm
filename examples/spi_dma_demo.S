@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/spi_dma_demo.S - SPI0 + DMA full-duplex via internal loopback (M4-G).
@
@ Two DMA channels operating concurrently:
@   * channel 0: paced by DREQ_SPI0_TX.  Reads from a 1024-byte source in
@     .rodata (incrementing read addr), writes to SSPDR (fixed dst).
@   * channel 1: paced by DREQ_SPI0_RX.  Reads from SSPDR (fixed src),
@     writes to a 1024-byte buffer in .bss (incrementing dst).
@
@ With LBM=1 the TX serialiser is wired straight into the RX serialiser, so
@ every byte clocked out by ch0 returns into the RX FIFO and gets pulled by
@ ch1.  Once both channels have completed and the SPI is no longer BSY, we
@ verify the destination matches the source byte-for-byte and report
@ "spi-dma OK" or "spi-dma FAIL <count>" via UART0.
@
@ Build:    make build/spi_dma_demo.uf2
@ Verify:   115200 8N1; expect
@             ticktrace M4-G: SPI0 DMA loopback demo
@             spi-dma OK
@           Or "spi-dma FAIL N" with N = mismatched bytes.
@ =============================================================================

    .include "rp2350.inc"
    .include "spi.inc"
    .include "dma.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ XFER_BYTES, 1024
    .equ TX_CHAN,    0
    .equ RX_CHAN,    1

@ ---- Source: 1 KiB of a recognisable word pattern --------------------------
    .section .rodata.spi_dma_src, "a"
    .align   2
    .global  spi_dma_src
spi_dma_src:
    .rept   (XFER_BYTES / 4)
    .word   0xA5C3F00D
    .endr

@ ---- Banners ---------------------------------------------------------------
    .section .rodata.spi_dma_banners, "a"
banner_intro:
    .asciz "ticktrace M4-G: SPI0 DMA loopback demo\r\n"
banner_pass:
    .asciz "spi-dma OK\r\n"
banner_fail_pre:
    .asciz "spi-dma FAIL "
banner_nl:
    .asciz "\r\n"

@ ---- Destination: 1 KiB in .bss --------------------------------------------
    .section .bss.spi_dma_dst, "aw", %nobits
    .align   2
    .global  spi_dma_dst
spi_dma_dst:
    .space   XFER_BYTES

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, r5, r6, r7, lr}

    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    @ ---- Bring up SPI0 in loopback at 1 MHz --------------------------------
    movs    r0, #0
    movw    r1, #(1000000 & 0xFFFF)
    movt    r1, #(1000000 >> 16)
    bl      spi_init

    movs    r0, #0
    movs    r1, #1
    bl      spi_set_loopback

    @ Enable both DMA request lines on the SPI side.
    movs    r0, #0
    movs    r1, #1                      @ tx_on
    movs    r2, #1                      @ rx_on
    bl      spi_set_dma_enabled

    @ ---- DMA controller bring-up ------------------------------------------
    bl      dma_init

    @ ---- Configure RX channel (ch1) FIRST so it's armed before TX kicks ---
    @ CTRL = EN | DATA_SIZE_BYTE | INCR_WRITE | (DREQ_SPI0_RX << TREQ_SEL_LSB)
    @ Note: read addr fixed (no INCR_READ).
    ldr     r1, =(DMA_CTRL_EN | DMA_DATA_SIZE_BYTE | DMA_CTRL_INCR_WRITE | (DREQ_SPI0_RX << DMA_CTRL_TREQ_SEL_LSB))

    movs    r0, #XFER_BYTES & 0xFF      @ low byte of count
    @ XFER_BYTES = 1024 doesn't fit movs immediate; load via ldr
    ldr     r0, =XFER_BYTES
    movs    r4, #1                      @ trigger
    push    {r0, r4}                    @ [sp]=count, [sp+4]=trigger

    movs    r0, #RX_CHAN                @ ch=1
    ldr     r2, =SPI0_BASE + SSPDR      @ src (fixed)
    ldr     r3, =spi_dma_dst            @ dst (incrementing)
    bl      dma_channel_configure
    add     sp, sp, #8

    @ ---- Configure TX channel (ch0) - this triggers the burst ------------
    ldr     r1, =(DMA_CTRL_EN | DMA_DATA_SIZE_BYTE | DMA_CTRL_INCR_READ | (DREQ_SPI0_TX << DMA_CTRL_TREQ_SEL_LSB))
    ldr     r0, =XFER_BYTES
    movs    r4, #1
    push    {r0, r4}

    movs    r0, #TX_CHAN
    ldr     r2, =spi_dma_src
    ldr     r3, =SPI0_BASE + SSPDR
    bl      dma_channel_configure
    add     sp, sp, #8

    @ Wait for both channels to finish, then for SPI to drain.
    movs    r0, #TX_CHAN
    bl      dma_channel_wait_for_finish
    movs    r0, #RX_CHAN
    bl      dma_channel_wait_for_finish

    @ Spin on SPI BSY=0 to make sure no straggler bytes are still on the wire.
    movs    r0, #0
1:  push    {r0}
    bl      spi_is_busy
    cmp     r0, #0
    pop     {r1}
    mov     r0, r1
    bne     1b

    @ ---- Verify dst == src -------------------------------------------------
    ldr     r4, =spi_dma_src
    ldr     r5, =spi_dma_dst
    movs    r6, #0                          @ mismatch count
    movs    r0, #0
.Lcheck:
    ldrb    r1, [r4, r0]
    ldrb    r2, [r5, r0]
    cmp     r1, r2
    beq     1f
    adds    r6, #1
1:  adds    r0, #1
    ldr     r7, =XFER_BYTES
    cmp     r0, r7
    blo     .Lcheck

    cbz     r6, .Lpass
    ldr     r0, =banner_fail_pre
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
2:  bl      gpio_led_toggle
    ldr     r0, =600000
3:  subs    r0, #1
    bne     3b
    b       2b

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
