@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/i2c_eeprom_demo.S - 24LC256-style EEPROM write/read demo (M4-F).
@
@ Talks to a fictional Microchip 24LC256 (32 KiB) EEPROM at 7-bit address
@ 0x50 on I2C0 (SDA = GP4, SCL = GP5) at 400 kHz.
@
@ Sequence:
@   1. Page-write: send {addr_hi, addr_lo, b0, b1, b2, b3} with STOP.
@   2. Random-read: send {addr_hi, addr_lo} with restart (nostop=1), then
@      read 4 bytes back with STOP at the end.
@   3. Print each byte over UART.
@
@ The Renode peripheral in tests/renode/i2c_peripheral.py answers reads at
@ address 0x50 with a fixed 0xA5 0xB6 0xC7 0xD8 pattern, so a successful
@ run prints "READ: A5 B6 C7 D8".
@
@ Build:  make build/i2c_eeprom_demo.uf2
@ =============================================================================

    .include "rp2350.inc"
    .include "i2c.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ I2C_IDX,           0
    .equ I2C_BAUD,          400000
    .equ SDA_PIN,           4
    .equ SCL_PIN,           5
    .equ EEPROM_ADDR,       0x50
    .equ EEPROM_OFFSET,     0x0010

@ ---- Banners ----------------------------------------------------------------
    .section .rodata.i2c_eeprom_banners, "a"
banner_intro:
    .asciz "rp-asm M4-F: I2C EEPROM demo @ 0x50, 400 kHz\r\n"
banner_write_done:
    .asciz "WROTE 4 bytes\r\n"
banner_read_pre:
    .asciz "READ: "
banner_nl:
    .asciz "\r\n"
banner_write_fail:
    .asciz "WRITE NACK\r\n"
banner_read_fail:
    .asciz "READ NACK\r\n"
banner_addr_fail:
    .asciz "ADDR NACK\r\n"
banner_sp:
    .asciz " "

@ ---- Buffers ----------------------------------------------------------------
    .section .data.i2c_eeprom_bufs, "aw"
    .align 4
    .global  write_buf
write_buf:
    .byte   (EEPROM_OFFSET >> 8) & 0xFF     @ addr hi
    .byte   EEPROM_OFFSET & 0xFF            @ addr lo
    .byte   0x11                            @ payload b0
    .byte   0x22                            @ payload b1
    .byte   0x33                            @ payload b2
    .byte   0x44                            @ payload b3

    .align 4
    .global  addr_buf
addr_buf:
    .byte   (EEPROM_OFFSET >> 8) & 0xFF
    .byte   EEPROM_OFFSET & 0xFF
    .byte   0
    .byte   0

    .section .bss.i2c_eeprom_rx, "aw", %nobits
    .align 4
    .global  read_buf
read_buf:
    .space  4

@ ---- main -------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, r5, lr}

    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    @ ---- I2C0 init at 400 kHz on GP4/GP5 ----------------------------------
    movs    r0, #I2C_IDX
    movs    r1, #SDA_PIN
    movs    r2, #SCL_PIN
    bl      i2c_set_pins
    movs    r0, #I2C_IDX
    ldr     r1, =I2C_BAUD
    bl      i2c_init

    @ ---- 1. Write {addr_hi, addr_lo, b0, b1, b2, b3} with STOP ----------
    movs    r0, #0
    movs    r1, #0
    push    {r0, r1}                        @ nostop = 0
    movs    r0, #I2C_IDX
    movs    r1, #EEPROM_ADDR
    ldr     r2, =write_buf
    movs    r3, #6
    bl      i2c_write_blocking
    add     sp, sp, #8

    cmn     r0, #1
    bne     1f
    ldr     r0, =banner_write_fail
    bl      uart0_puts
    b       .Lpark
1:  ldr     r0, =banner_write_done
    bl      uart0_puts

    @ ---- 2a. Set the EEPROM read pointer (write 2 addr bytes, no stop) ---
    movs    r0, #1
    movs    r1, #0
    push    {r0, r1}                        @ nostop = 1 (hold bus for restart)
    movs    r0, #I2C_IDX
    movs    r1, #EEPROM_ADDR
    ldr     r2, =addr_buf
    movs    r3, #2
    bl      i2c_write_blocking
    add     sp, sp, #8

    cmn     r0, #1
    bne     2f
    ldr     r0, =banner_addr_fail
    bl      uart0_puts
    b       .Lpark
2:
    @ ---- 2b. Random-read 4 bytes (with STOP after the last) --------------
    movs    r0, #0
    movs    r1, #0
    push    {r0, r1}                        @ nostop = 0
    movs    r0, #I2C_IDX
    movs    r1, #EEPROM_ADDR
    ldr     r2, =read_buf
    movs    r3, #4
    bl      i2c_read_blocking
    add     sp, sp, #8

    cmn     r0, #1
    bne     3f
    ldr     r0, =banner_read_fail
    bl      uart0_puts
    b       .Lpark
3:
    @ ---- 3. Print "READ: B0 B1 B2 B3" -----------------------------------
    ldr     r0, =banner_read_pre
    bl      uart0_puts

    movs    r4, #0
    ldr     r5, =read_buf
.Lprint_loop:
    ldrb    r0, [r5, r4]
    bl      print_hex_byte
    ldr     r0, =banner_sp
    bl      uart0_puts
    adds    r4, #1
    cmp     r4, #4
    blo     .Lprint_loop

    ldr     r0, =banner_nl
    bl      uart0_puts

.Lpark:
    bl      gpio_led_toggle
    ldr     r0, =3000000
4:  subs    r0, #1
    bne     4b
    b       .Lpark

@ ----------------------------------------------------------------------------
@ print_hex_byte (shared with i2c_scan_demo - reuse-friendly).
@ ----------------------------------------------------------------------------
    .section .text.print_hex_byte, "ax"
    .thumb_func
    .global  print_hex_byte
print_hex_byte:
    push    {r4, lr}
    mov     r4, r0
    lsrs    r0, r4, #4
    bl      print_hex_nibble
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
