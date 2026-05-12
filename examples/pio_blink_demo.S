@ =============================================================================
@ pio_blink_demo.S - drive GP25 (LED) from PIO0 SM0 using a hand-encoded blink
@                    program. Demonstrates the M5-I controller API end-to-end.
@
@ PIO program (hand-encoded; a Python pioasm is deferred):
@   instr[0] = SET PINS, 1 [31]      ; 0xFF01
@   instr[1] = SET PINS, 0 [31]      ; 0xFF00
@   WRAP_TOP=1, WRAP_BOTTOM=0 so SM loops without a JMP.
@
@ Each instruction takes (1 + 31) = 32 PIO cycles, so one toggle = 64 PIO
@ cycles.  With CLKDIV_INT = 0xFFFF and clk_sys = 150 MHz, that's
@ 64 * 65535 / 150e6 ≈ 28 ms per full cycle (~36 Hz) — easy to capture on a
@ logic analyser; on real hardware the LED looks dim/solid because it's
@ above the persistence-of-vision frequency.  Print a banner so the UART
@ confirms the firmware booted.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ LED_PIN, 25
    .equ PIO_BLINK_LEN, 2

    .section .rodata.demo, "a"
    .align 2
banner:
    .asciz "pio0 sm0 blinking GP25\r\n"

@ Program instructions stored 1 per 32-bit word; only the low 16 bits matter.
pio_blink_program:
    .word 0xFF01            @ SET PINS, 1 [31]
    .word 0xFF00            @ SET PINS, 0 [31]

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      gpio_led_init                   @ keep GP25 LED owned by SIO for default low
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    ldr     r0, =banner
    bl      uart0_puts

    @ ---- PIO0 bring-up ---------------------------------------------------
    movs    r0, #0
    bl      pio_init

    @ Route GP25 to PIO0 (funcsel = 6)
    movs    r0, #0                          @ pio idx
    movs    r1, #LED_PIN
    bl      pio_gpio_init

    @ Load 2-instruction program at origin 0
    movs    r0, #0                          @ pio idx
    ldr     r1, =pio_blink_program
    movs    r2, #PIO_BLINK_LEN
    movs    r3, #0                          @ origin
    bl      pio_add_program

    @ CLKDIV max (slowest)
    movs    r0, #0
    movs    r1, #0                          @ sm
    movw    r2, #0xFFFF                     @ int
    movs    r3, #0                          @ frac
    bl      pio_sm_set_clkdiv

    @ WRAP: bottom=0, top=1
    movs    r0, #0
    movs    r1, #0
    movs    r2, #0
    movs    r3, #1
    bl      pio_sm_set_wrap

    @ SET pin range: base=LED_PIN, count=1
    movs    r0, #0
    movs    r1, #0
    movs    r2, #LED_PIN
    movs    r3, #1
    bl      pio_sm_set_set_pins

    @ Enable SM0
    movs    r0, #0
    movs    r1, #0
    movs    r2, #1
    bl      pio_sm_set_enabled

.Lloop:
    wfi
    b       .Lloop
