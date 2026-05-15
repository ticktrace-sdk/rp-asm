@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/i2c_master_slave_loopback_demo.S - I2C0 master <-> I2C1 slave loop.
@
@ Wiring (board-side; demo expects the two instances tied together):
@   I2C0 SDA = GP4   <----> I2C1 SDA = GP6
@   I2C0 SCL = GP5   <----> I2C1 SCL = GP7
@
@ Slave address: 0x42 on I2C1.
@
@ Sequence:
@   1. Bring up I2C0 as master, I2C1 as slave at 0x42.
@   2. Install I2C1_IRQ handler that:
@         - on RX_FULL : pop bytes from RX FIFO into rx_buf[]
@         - on STOP_DET: increment stop_count
@   3. Master writes "hello\0" (6 bytes) with STOP -> slave ISR captures.
@   4. Master then reads 1 byte back from slave at 0x42 (the slave's TX FIFO
@      was pre-loaded with stop_count - works because the DesignWare slave
@      auto-drives whatever the master clocks out of TX FIFO).
@   5. Print the captured byte over UART.
@
@ Build: make build/i2c_master_slave_loopback_demo.uf2
@ =============================================================================

    .include "rp2350.inc"
    .include "i2c.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ M_IDX,             0
    .equ S_IDX,             1
    .equ M_SDA,             4
    .equ M_SCL,             5
    .equ S_SDA,             6
    .equ S_SCL,             7
    .equ SLAVE_ADDR,        0x42
    .equ BAUD,              100000

    .equ NVIC_ISER1,        0xE000E104       @ IRQs 32..63
    .equ NUM_VECTORS,       64
    .equ I2C1_VECTOR_INDEX, (16 + I2C1_IRQ)  @ 16 + 36 = 52

@ ---- Banners ----------------------------------------------------------------
    .section .rodata.i2c_loop_banners, "a"
banner_intro:
    .asciz "rp-asm M4-F: I2C master/slave loopback demo\r\n"
banner_master_w_done:
    .asciz "MASTER WROTE hello\r\n"
banner_master_w_fail:
    .asciz "MASTER WRITE NACK\r\n"
banner_master_r_pre:
    .asciz "MASTER READ stop_count = 0x"
banner_master_r_fail:
    .asciz "MASTER READ NACK\r\n"
banner_nl:
    .asciz "\r\n"

msg_hello:
    .ascii "hello"
    .byte  0
msg_hello_end:
    .equ HELLO_LEN, msg_hello_end - msg_hello

@ ---- ISR-visible state ------------------------------------------------------
    .section .bss.i2c_loop_state, "aw", %nobits
    .align 4
    .global  rx_buf
rx_buf:
    .space  16
    .global  rx_idx
rx_idx:
    .space  4
    .global  stop_count
stop_count:
    .space  4

    @ ---- Custom vector table at align(256) ---------------------------------
    .align 8
    .global  i2c_loop_vectors
i2c_loop_vectors:
    .space  NUM_VECTORS * 4

    .section .bss.i2c_loop_read, "aw", %nobits
    .align 4
read_byte:
    .space  4

@ ---- main -------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, r5, lr}

    @ ---- Boilerplate clocks/UART -----------------------------------------
    bl      gpio_led_init
    bl      uart0_init
    ldr     r0, =banner_intro
    bl      uart0_puts

    @ ---- Pin configs -----------------------------------------------------
    movs    r0, #M_IDX
    movs    r1, #M_SDA
    movs    r2, #M_SCL
    bl      i2c_set_pins
    movs    r0, #S_IDX
    movs    r1, #S_SDA
    movs    r2, #S_SCL
    bl      i2c_set_pins

    @ ---- I2C1 first as slave at 0x42 -------------------------------------
    movs    r0, #S_IDX
    ldr     r1, =BAUD
    bl      i2c_init
    movs    r0, #S_IDX
    movs    r1, #SLAVE_ADDR
    bl      i2c_set_slave_mode

    @ Enable RX_FULL + STOP_DET interrupts on the slave.
    movs    r0, #S_IDX
    movw    r1, #(IC_INTR_RX_FULL | IC_INTR_STOP_DET)
    bl      i2c_set_irqs_enabled

    @ ---- Build runtime vector table --------------------------------------
    @ Step 1: copy first 16 entries from the build-time _vectors so SP /
    @ Reset_Handler / hard-fault stubs all keep working through VTOR.
    ldr     r0, =_vectors
    ldr     r1, =i2c_loop_vectors
    movs    r2, #16
1:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    subs    r2, #1
    bne     1b

    @ Step 2: install i2c1_isr at slot I2C1_VECTOR_INDEX.
    ldr     r0, =i2c_loop_vectors
    ldr     r1, =i2c1_isr + 1                @ Thumb bit
    str     r1, [r0, #(I2C1_VECTOR_INDEX * 4)]

    @ Step 3: VTOR <- i2c_loop_vectors
    ldr     r0, =SCB_VTOR
    ldr     r1, =i2c_loop_vectors
    str     r1, [r0]

    @ Step 4: NVIC enable IRQ I2C1_IRQ (=36) -> ISER1 bit (36 - 32) = 4.
    movs    r1, #1
    lsls    r1, #(I2C1_IRQ - 32)
    ldr     r0, =NVIC_ISER1
    str     r1, [r0]

    @ ---- I2C0 as master ---------------------------------------------------
    movs    r0, #M_IDX
    ldr     r1, =BAUD
    bl      i2c_init

    @ ---- Master writes "hello\0" with STOP --------------------------------
    movs    r0, #0
    movs    r1, #0
    push    {r0, r1}                         @ nostop = 0
    movs    r0, #M_IDX
    movs    r1, #SLAVE_ADDR
    ldr     r2, =msg_hello
    movs    r3, #HELLO_LEN
    bl      i2c_write_blocking
    add     sp, sp, #8

    cmn     r0, #1
    bne     2f
    ldr     r0, =banner_master_w_fail
    bl      uart0_puts
    b       .Lpark
2:  ldr     r0, =banner_master_w_done
    bl      uart0_puts

    @ ---- Pre-load slave's TX FIFO with stop_count for the master read ----
    @ Slave responds with whatever is in its TX FIFO when the master clocks
    @ a read.  We push stop_count[0] there.
    ldr     r0, =stop_count
    ldr     r0, [r0]
    ldr     r1, =I2C1_BASE
    str     r0, [r1, #IC_DATA_CMD]

    @ ---- Master reads 1 byte ----------------------------------------------
    movs    r0, #0
    movs    r1, #0
    push    {r0, r1}                         @ nostop = 0
    movs    r0, #M_IDX
    movs    r1, #SLAVE_ADDR
    ldr     r2, =read_byte
    movs    r3, #1
    bl      i2c_read_blocking
    add     sp, sp, #8

    cmn     r0, #1
    bne     3f
    ldr     r0, =banner_master_r_fail
    bl      uart0_puts
    b       .Lpark
3:
    ldr     r0, =banner_master_r_pre
    bl      uart0_puts
    ldr     r0, =read_byte
    ldrb    r0, [r0]
    bl      print_hex_byte
    ldr     r0, =banner_nl
    bl      uart0_puts

.Lpark:
    bl      gpio_led_toggle
    ldr     r0, =3000000
4:  subs    r0, #1
    bne     4b
    b       .Lpark

@ ----------------------------------------------------------------------------
@ i2c1_isr - I2C1 interrupt service routine.
@   On RX_FULL : drain RX FIFO into rx_buf[] until empty.
@   On STOP_DET: increment stop_count, clear the source.
@ ----------------------------------------------------------------------------
    .section .text.i2c1_isr, "ax"
    .thumb_func
    .global  i2c1_isr
i2c1_isr:
    push    {r4, r5, r6, lr}
    ldr     r4, =I2C1_BASE

    @ Snapshot the masked interrupt status
    ldr     r5, [r4, #IC_INTR_STAT]

    @ ---- RX_FULL : drain bytes -----------------------------------------
    movs    r6, #IC_INTR_RX_FULL
    tst     r5, r6
    beq     2f
.Ldrain:
    ldr     r0, [r4, #IC_STATUS]
    movs    r1, #IC_STATUS_RFNE
    tst     r0, r1
    beq     2f
    ldr     r0, [r4, #IC_DATA_CMD]
    @ Append into rx_buf[rx_idx], then bump rx_idx (capped at 15)
    ldr     r1, =rx_idx
    ldr     r2, [r1]
    cmp     r2, #15
    bhs     1f
    ldr     r3, =rx_buf
    strb    r0, [r3, r2]
    adds    r2, #1
    str     r2, [r1]
1:  b       .Ldrain
2:
    @ ---- STOP_DET : bump counter ---------------------------------------
    movw    r6, #IC_INTR_STOP_DET
    tst     r5, r6
    beq     3f
    ldr     r0, =stop_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    @ Clear STOP_DET source by reading IC_CLR_STOP_DET
    ldr     r0, [r4, #IC_CLR_STOP_DET]
3:
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ print_hex_byte - reused from the other I2C demos.
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
