@ =============================================================================
@ uart.S - UART0 on GPIO0 (TX) / GPIO1 (RX), 115200 8N1
@
@ Clock assumption: clk_peri == 12 MHz (post-bootrom default; XOSC straight
@ through with no PLL).  If you later bring up clk_sys at 150 MHz, you must
@ recompute IBRD/FBRD or this driver will run at 1/12.5 of the intended rate.
@
@ Baud math for 12 MHz / (16 * 115200) = 6.5104:
@   IBRD = 6
@   FBRD = round(0.5104 * 64) = 33
@   actual = 12e6 / (16 * (6 + 33/64)) = 115,108 Bd  (-0.08% error, OK)
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ UART_TX_PIN, 0
    .equ UART_RX_PIN, 1

@ ----------------------------------------------------------------------------
@ uart0_init - bring pads + IO mux + UART up at 115200 8N1, TX+RX enabled.
@ Assumes startup.S has already deasserted RESETS_uart0.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.uart0_init, "ax"
    .thumb_func
    .global  uart0_init
uart0_init:
    @ ---- Clear ISO/OD on both pads via atomic CLR --------------------------
    movs    r2, #(0x180 >> 7)       @ 0x180 = ISO|OD; keep movs immediate small
    lsls    r2, #7                  @ r2 = 0x180

    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (UART_TX_PIN * PADS_BANK0_PAD_STRIDE)
    str     r2, [r0]
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (UART_RX_PIN * PADS_BANK0_PAD_STRIDE)
    str     r2, [r0]

    @ ---- IO_BANK0: FUNCSEL = UART for both pins ----------------------------
    movs    r2, #GPIO_FUNC_UART
    ldr     r0, =IO_BANK0_BASE + 4 + (UART_TX_PIN * IO_BANK0_GPIO_CTRL_STRIDE)
    str     r2, [r0]
    ldr     r0, =IO_BANK0_BASE + 4 + (UART_RX_PIN * IO_BANK0_GPIO_CTRL_STRIDE)
    str     r2, [r0]

    @ ---- PL011: program baud and line control ------------------------------
    ldr     r3, =UART0_BASE

    movs    r2, #6                  @ IBRD
    str     r2, [r3, #UART_IBRD]
    movs    r2, #33                 @ FBRD
    str     r2, [r3, #UART_FBRD]

    @ LCR_H = (WLEN=3 << 5) | (FEN << 4) = 0x70 -> 8 bits, FIFOs on, no parity
    movs    r2, #0x70
    str     r2, [r3, #UART_LCR_H]

    @ CR = (RXE<<9)|(TXE<<8)|UARTEN = 0x301
    movw    r2, #0x301
    str     r2, [r3, #UART_CR]

    bx      lr

@ ----------------------------------------------------------------------------
@ uart0_putc - blocking putchar.
@ Input:  r0 = byte (low 8 bits)
@ Spin loop:  ldr / tst / bne  = 3-4 cycles when FIFO has space.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.uart0_putc, "ax"
    .thumb_func
    .global  uart0_putc
uart0_putc:
    ldr     r3, =UART0_BASE
1:  ldr     r2, [r3, #UART_FR]
    lsls    r2, #(31 - 5)           @ TXFF -> N flag
    bmi     1b
    str     r0, [r3, #UART_DR]
    bx      lr

@ ----------------------------------------------------------------------------
@ uart0_puts - null-terminated string.
@ Input:  r0 = pointer
@ Clobbers: r0-r4, lr.
@ ----------------------------------------------------------------------------
    .section .text.uart0_puts, "ax"
    .thumb_func
    .global  uart0_puts
uart0_puts:
    push    {r4, lr}
    mov     r4, r0
1:  ldrb    r0, [r4], #1
    cbz     r0, 2f
    bl      uart0_putc
    b       1b
2:  pop     {r4, pc}
