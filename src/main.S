@ =============================================================================
@ main.S - blinky + UART "tick" loop
@
@ With clk_sys = 12 MHz and a 3-cycle inner loop body (subs+bne), each delay
@ iteration is ~250 ns.  DELAY_COUNT = 1_000_000 ~ 250 ms half-period -> 2 Hz.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ DELAY_COUNT, 1000000

    .section .rodata.banner, "a"
banner:
    .asciz "rp-asm v0.1 - every cycle matters\r\n"
tick_msg:
    .asciz "tick\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner
    bl      uart0_puts

.Lloop:
    bl      gpio_led_toggle

    ldr     r0, =tick_msg
    bl      uart0_puts

    ldr     r0, =DELAY_COUNT
1:  subs    r0, #1
    bne     1b

    b       .Lloop
