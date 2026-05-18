@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/spi_master_slave_loopback_demo.S
@   Wire SPI0 (master) <-> SPI1 (slave) externally and ping a "PING" message.
@
@ Pin layout (Pico 2 silkscreen):
@   SPI0 master pads: SCK=GP18, MOSI=GP19, MISO=GP16, CS=GP17 (SIO output)
@   SPI1 slave  pads: SCK=GP10, MOSI=GP11, MISO=GP12, CS=GP13 (SIO input)
@
@   Required jumpers:
@     GP18  ---  GP10        (SCK0 -> SCK1)
@     GP19  ---  GP11        (MOSI0 -> MOSI1, master TX -> slave RX)
@     GP16  ---  GP12        (MISO0 -> MISO1, slave TX -> master RX)
@     GP17  ---  GP13        (CS0 -> CS1, master SIO drives slave CS pad)
@
@ Sequence:
@   1. spi_init(0, 1_000_000) - master at 1 MHz
@   2. spi_init(1, 1_000_000) ; spi_set_slave(1, 1) - slave config
@   3. spi_set_pins on each instance (sck/mosi/miso to SPI; CS to SIO out
@      for master, SIO in for slave - we only configure the master CS here,
@      the slave reads its FSS line via the FUNCSEL=SPI mux on the wire).
@   4. master pushes "PING" + null terminator (5 bytes), CS bracketed.
@   5. After CS rises and the SPI drains, master clocks out 5 dummy bytes
@      and reads back what the slave's RX FIFO captured (slave echoes via
@      its TX FIFO which the master sees on its MISO).
@   6. Print the captured echo string via UART0.
@
@ NOTE on slave-mode echo: PL022 in slave mode shifts whatever's in the
@ slave's TX FIFO out on MISO each frame.  We pre-load the slave TX FIFO
@ with the bytes we want it to echo back - this gives us a deterministic
@ data path even without an interrupt service.
@
@ Build:    make build/spi_master_slave_loopback_demo.uf2
@ Verify:   115200 8N1 + jumpers as above; expect:
@             ticktrace M4-G: SPI master/slave loopback
@             slave got: PING
@           If the jumpers are missing the line will read all zeros and the
@           output is "slave got: " (empty).
@ =============================================================================

    .include "rp2350.inc"
    .include "spi.inc"
    .include "gpio.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----- Pin assignments ------------------------------------------------------
    .equ MASTER_SCK,  18
    .equ MASTER_MOSI, 19
    .equ MASTER_MISO, 16
    .equ MASTER_CS,   17

    .equ SLAVE_SCK,   10
    .equ SLAVE_MOSI,  11
    .equ SLAVE_MISO,  12
    .equ SLAVE_CS,    13      @ slave-side FSS comes from FUNCSEL=SPI on the pin

    .equ MSG_LEN,     5       @ "PING\0"

@ ----- ROdata: outbound message + banners -----------------------------------
    .section .rodata.spi_ms_data, "a"
    .align   2
ms_msg:
    .byte    'P', 'I', 'N', 'G', 0
    .align   2

banner_intro:
    .asciz "ticktrace M4-G: SPI master/slave loopback\r\n"
banner_got:
    .asciz "slave got: "
banner_nl:
    .asciz "\r\n"

@ ----- BSS: receive buffer (slave's RX FIFO content) ------------------------
    .section .bss.spi_ms_rx, "aw", %nobits
    .align   2
ms_rx:
    .space   MSG_LEN

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, r5, lr}

    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    @ ---- Bring up SPI0 (master) -------------------------------------------
    movs    r0, #0
    movw    r1, #(1000000 & 0xFFFF)
    movt    r1, #(1000000 >> 16)
    bl      spi_init

    @ ---- Bring up SPI1 (slave) --------------------------------------------
    movs    r0, #1
    movw    r1, #(1000000 & 0xFFFF)
    movt    r1, #(1000000 >> 16)
    bl      spi_init

    movs    r0, #1
    movs    r1, #1
    bl      spi_set_slave

    @ ---- Pin mux ----------------------------------------------------------
    @ SPI0: sck/mosi/miso to SPI; CS = SIO out (we drive it for the slave's
    @       FSS pad below).
    movs    r0, #0
    movs    r1, #MASTER_SCK
    movs    r2, #MASTER_MOSI
    movs    r3, #MASTER_MISO
    movs    r4, #MASTER_CS
    push    {r4}
    bl      spi_set_pins
    add     sp, sp, #4

    @ SPI1: sck/mosi/miso/cs all to SPI - the slave's FSS pin must be in
    @       FUNCSEL=SPI to receive our master's CS line.  We pass MASTER_CS
    @       as the cs argument with -1 to tell spi_set_pins to skip CS init,
    @       then funcsel SLAVE_CS to SPI manually.
    movs    r0, #1
    movs    r1, #SLAVE_SCK
    movs    r2, #SLAVE_MOSI
    movs    r3, #SLAVE_MISO
    movs    r4, #-1
    push    {r4}
    bl      spi_set_pins
    add     sp, sp, #4

    movs    r0, #SLAVE_CS
    movs    r1, #GPIO_FUNC_SPI
    bl      gpio_set_function

    @ ---- Pre-load slave TX FIFO with echo data so the master's read pass
    @      receives "PING\0" back on MISO.
    @ The slave shifts whatever's in SSPDR out on MISO each frame.  Push 5
    @ bytes ahead of the master starting to clock.  PL022's slave TX FIFO
    @ holds 8 entries so 5 fits.
    ldr     r4, =SPI1_BASE + SSPDR
    ldr     r5, =ms_msg
    movs    r0, #0
1:  ldrb    r1, [r5, r0]
    str     r1, [r4]
    adds    r0, #1
    cmp     r0, #MSG_LEN
    blo     1b

    @ ---- Bracket the master's TX with CS active-low ----------------------
    movs    r0, #MASTER_CS
    bl      spi_cs_low

    @ Master pushes the 5-byte message; slave's RX FIFO captures it.
    @ Use the blocking write so we discard the slave's MISO (which is the
    @ pre-loaded "PING\0" - we'll re-read it on the next pass).
    movs    r0, #0
    ldr     r1, =ms_msg
    movs    r2, #MSG_LEN
    bl      spi_write_blocking

    movs    r0, #MASTER_CS
    bl      spi_cs_high

    @ ---- Drain the slave's RX FIFO into ms_rx[] --------------------------
    ldr     r4, =SPI1_BASE
    ldr     r5, =ms_rx
    movs    r0, #0
2:  @ Wait for RNE on slave
3:  ldr     r1, [r4, #SSPSR]
    movs    r2, #SSPSR_RNE
    tst     r1, r2
    beq     3b
    ldr     r1, [r4, #SSPDR]
    strb    r1, [r5, r0]
    adds    r0, #1
    cmp     r0, #MSG_LEN
    blo     2b

    @ ---- Print the captured bytes ----------------------------------------
    ldr     r0, =banner_got
    bl      uart0_puts
    ldr     r0, =ms_rx
    bl      uart0_puts                  @ ms_rx is null-terminated by msg_len-1=4
    ldr     r0, =banner_nl
    bl      uart0_puts

.Lhalt:
    bl      gpio_led_toggle
    ldr     r0, =600000
4:  subs    r0, #1
    bne     4b
    b       .Lhalt
