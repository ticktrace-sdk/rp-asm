@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/i2c_scan_demo.S - 7-bit I2C bus scan on I2C0 (SDA=GP4, SCL=GP5).
@
@ Walks every reserved-range-excluded address 0x08..0x77 inclusive, attempts
@ a zero-length write (which the DesignWare controller turns into "address
@ phase + STOP"); if no TX_ABRT is reported the slave ACKed and we print the
@ address.  Otherwise we silently move on.
@
@ At the end we print "scan done\r\n" so the test harness has a deterministic
@ end-of-banner sentinel.
@
@ Build:    make build/i2c_scan_demo.uf2
@ Verify:   115200 8N1 on GP0; expected (with no slaves attached) just the
@           start banner + "scan done".  With a 24LC256 EEPROM at 0x50 you
@           should also see "0x50 ACK".
@ =============================================================================

    .include "rp2350.inc"
    .include "i2c.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ I2C_IDX,           0
    .equ I2C_BAUD,          100000
    .equ SDA_PIN,           4
    .equ SCL_PIN,           5
    .equ ADDR_LO,           0x08
    .equ ADDR_HI,           0x77

@ ---- Banners ----------------------------------------------------------------
    .section .rodata.i2c_scan_banners, "a"
banner_intro:
    .asciz "rp-asm M4-F: I2C bus scan on GP4/GP5 @ 100 kHz\r\n"
banner_done:
    .asciz "scan done\r\n"
banner_ack_pre:
    .asciz "0x"
banner_ack_post:
    .asciz " ACK\r\n"

@ ---- Tiny stack-allocated 1-byte zero buffer for write_blocking -------------
    .section .bss.i2c_zero, "aw", %nobits
    .align 4
zero_byte:
    .space 4

@ ---- main -------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, r5, lr}

    @ ---- UART (12 MHz default; same bring-up as the dma demos) -------------
    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    @ ---- I2C0 init at 100 kHz on GP4/GP5 ----------------------------------
    movs    r0, #I2C_IDX
    movs    r1, #SDA_PIN
    movs    r2, #SCL_PIN
    bl      i2c_set_pins

    movs    r0, #I2C_IDX
    ldr     r1, =I2C_BAUD
    bl      i2c_init

    @ ---- Sweep 0x08..0x77 --------------------------------------------------
    movs    r4, #ADDR_LO

.Lscan_loop:
    @ Try a zero-length write (probe).  args:
    @   r0 = idx, r1 = addr, r2 = src, r3 = len
    @   [sp,#0] = nostop_bool   (we want STOP after probe)
    movs    r0, #0
    movs    r1, #0
    push    {r0, r1}                        @ nostop = 0 at [sp,#0], pad at #4
    movs    r0, #I2C_IDX
    mov     r1, r4
    ldr     r2, =zero_byte
    movs    r3, #0
    bl      i2c_write_blocking
    add     sp, sp, #8

    @ r0 = bytes_written or -1.  -1 means TX_ABRT.
    cmn     r0, #1                          @ r0 == -1 ?
    beq     .Lnack

    @ ACK: print "0xNN ACK\r\n"
    ldr     r0, =banner_ack_pre
    bl      uart0_puts
    mov     r0, r4
    bl      print_hex_byte
    ldr     r0, =banner_ack_post
    bl      uart0_puts

.Lnack:
    adds    r4, #1
    cmp     r4, #ADDR_HI
    bls     .Lscan_loop

    ldr     r0, =banner_done
    bl      uart0_puts

.Lpark:
    bl      gpio_led_toggle
    ldr     r0, =3000000
1:  subs    r0, #1
    bne     1b
    b       .Lpark

@ ----------------------------------------------------------------------------
@ print_hex_byte(uint8_t x) - emit two hex nibbles via uart0_putc.
@   Clobbers r0-r3, lr.
@ ----------------------------------------------------------------------------
    .section .text.print_hex_byte, "ax"
    .thumb_func
    .global  print_hex_byte
print_hex_byte:
    push    {r4, lr}
    mov     r4, r0
    @ High nibble
    lsrs    r0, r4, #4
    bl      print_hex_nibble
    @ Low nibble
    mov     r0, r4
    bl      print_hex_nibble
    pop     {r4, pc}

    .thumb_func
    .global  print_hex_nibble
print_hex_nibble:
    push    {lr}
    movs    r1, #0xF
    ands    r0, r1
    cmp     r0, #10
    blo     1f
    add     r0, #('a' - 10)
    b       2f
1:  add     r0, #'0'
2:  bl      uart0_putc
    pop     {pc}
