@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/dma_sniff_demo.S - DMA sniffer / CRC32 demo (M3-C).
@
@ Configures DMA channel 0 to copy a 256-byte known-pattern buffer with the
@ sniffer enabled in CRC32 mode, then prints the resulting CRC over UART.
@
@ The CRC32 reference value (poly 0xEDB88320, init 0xFFFFFFFF, no final XOR)
@ for 256 copies of 0xC001CAFE-as-LE-words is well-defined; we don't assert
@ on it in firmware (no FP, no test vector table) - the human reads the hex
@ from the UART and compares against an external reference (e.g. zlib.crc32
@ on the same buffer).
@
@ Build:    make examples/dma_sniff_demo.uf2  ->  build/dma_sniff_demo.uf2
@ Verify:   115200 8N1 on GP0; expect
@             rp-asm M3-C: DMA sniff demo
@             CRC32 = 0xXXXXXXXX
@ =============================================================================

    .include "rp2350.inc"
    .include "dma.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ COPY_BYTES, 256
    .equ COPY_WORDS, (COPY_BYTES / 4)

@ ---- Source buffer (.rodata; 256 bytes of 0xC001CAFE pattern). --------------
    .section .rodata.sniff_src, "a"
    .align   4
sniff_src:
    .rept   COPY_WORDS
    .word   0xC001CAFE
    .endr

@ ---- Destination buffer (.bss). --------------------------------------------
    .section .bss.sniff_dst, "aw", %nobits
    .align   4
sniff_dst:
    .space   COPY_BYTES

@ ---- Banners --------------------------------------------------------------
    .section .rodata.banners, "a"
banner_intro:
    .asciz "rp-asm M3-C: DMA sniff demo\r\n"
banner_crc:
    .asciz "CRC32 = 0x"
banner_nl:
    .asciz "\r\n"

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, lr}

    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    bl      dma_init

    @ ---- Enable sniffer in CRC32 mode on channel 0 ------------------------
    movs    r0, #0                          @ ch
    movs    r1, #DMA_SNIFF_CRC32            @ mode
    bl      dma_sniff_enable

    @ ---- Configure ch0 with SNIFF_EN=1 in CTRL ----------------------------
    @ Standard mem2mem WORD CTRL plus SNIFF_EN.
    ldr     r1, =(DMA_CTRL_MEM2MEM_WORD | DMA_CTRL_SNIFF_EN)

    movs    r0, #COPY_WORDS
    movs    r4, #1
    push    {r0, r4}                        @ count, trigger

    movs    r0, #0
    ldr     r2, =sniff_src
    ldr     r3, =sniff_dst
    bl      dma_channel_configure

    movs    r0, #0
    bl      dma_channel_wait_for_finish

    add     sp, sp, #8

    @ ---- Print CRC -------------------------------------------------------
    ldr     r0, =banner_crc
    bl      uart0_puts

    bl      dma_sniff_get_data              @ -> r0
    bl      print_hex32

    ldr     r0, =banner_nl
    bl      uart0_puts

    @ Park.
.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =3000000
1:  subs    r0, #1
    bne     1b
    b       .Lloop

@ ----------------------------------------------------------------------------
@ print_hex32(uint32_t x) - emit `x` as 8 hex chars (no 0x prefix).
@ Clobbers: r0-r3, lr.
@ ----------------------------------------------------------------------------
    .section .text.print_hex32, "ax"
    .thumb_func
    .global  print_hex32
print_hex32:
    push    {r4, r5, lr}
    mov     r4, r0
    movs    r5, #8                          @ nibbles to emit
1:  movs    r0, r4
    lsrs    r0, #28                         @ top nibble
    cmp     r0, #10
    blt     2f
    add     r0, #('A' - '0' - 10)
2:  add     r0, #'0'
    bl      uart0_putc
    lsls    r4, #4
    subs    r5, #1
    bne     1b
    pop     {r4, r5, pc}
