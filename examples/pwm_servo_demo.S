@ =============================================================================
@ examples/pwm_servo_demo.S - 50 Hz hobby-servo signal on GP15 (slice 7B).
@
@ Servo math:
@   period       = 20 ms  (50 Hz)
@   pulse width  = 1 ms (full CCW) .. 1.5 ms (centre) .. 2 ms (full CW)
@
@ We pick a tick rate of 1 us so TOP+1 = 20000 gives exactly 20 ms.  At
@ clk_sys = 150 MHz we need DIV.int = 150 to scale 150 MHz down to 1 MHz.
@ Then a duty level in the same 1 us units = 1000 .. 2000.
@
@ The example walks 1ms -> 1.5ms -> 2ms -> 1.5ms -> repeat once per second
@ (busy-loop based 1 second delay; ~20 cycle accurate enough for this).
@ A line is printed over UART at each step describing the new pulse width.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "src/pwm.S"

    .equ SERVO_PIN,         15
    .equ SERVO_SLICE,       PWM_SLICE_FOR_GP15      @ = 7
    .equ SERVO_CHAN,        PWM_CHAN_FOR_GP15       @ = 1 (B)
    .equ SERVO_TOP,         20000                   @ 20 ms @ 1 us tick
    .equ SERVO_DIV_INT,     150                     @ 150 MHz / 150 = 1 MHz

    @ 1 second of busy loop at 150 MHz / 3-cycle inner = 50_000_000.
    .equ SECOND_DELAY,      50000000

    .section .rodata.banner_pwm_servo, "a"
banner:
    .asciz "pwm servo demo: GP15 50Hz\r\n"
msg_1ms:
    .asciz "  1.0ms CCW\r\n"
msg_15ms:
    .asciz "  1.5ms ctr\r\n"
msg_2ms:
    .asciz "  2.0ms CW\r\n"

    .align 2
servo_steps:
    .word msg_1ms
    .hword 1000
    .hword 0                            @ pad to 8 B/entry
    .word msg_15ms
    .hword 1500
    .hword 0
    .word msg_2ms
    .hword 2000
    .hword 0
    .word msg_15ms
    .hword 1500
    .hword 0

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    ldr     r0, =banner
    bl      uart0_puts

    bl      pwm_init

    movs    r0, #SERVO_PIN
    bl      pwm_set_gpio_function

    movs    r0, #SERVO_SLICE
    movw    r1, #SERVO_DIV_INT
    bl      pwm_set_clkdiv_int

    movs    r0, #SERVO_SLICE
    movw    r1, #SERVO_TOP
    bl      pwm_set_wrap

    @ Start centred at 1.5 ms
    movs    r0, #SERVO_SLICE
    movs    r1, #SERVO_CHAN
    movw    r2, #1500
    bl      pwm_set_chan_level

    movs    r0, #SERVO_SLICE
    movs    r1, #1
    bl      pwm_set_enabled

    @ Step table: each entry is { msg_ptr, pulse_us }.
.Lservo_loop:
    ldr     r4, =servo_steps
    movs    r5, #4                      @ 4 entries
.Lstep:
    ldr     r0, [r4]                    @ message ptr
    bl      uart0_puts

    movs    r0, #SERVO_SLICE
    movs    r1, #SERVO_CHAN
    ldrh    r2, [r4, #4]                @ pulse_us
    bl      pwm_set_chan_level

    bl      delay_one_second

    adds    r4, #8
    subs    r5, #1
    bne     .Lstep
    b       .Lservo_loop

@ ----------------------------------------------------------------------------
@ delay_one_second - busy loop ~1 s at 150 MHz.
@ Clobbers: r0.
@ ----------------------------------------------------------------------------
    .section .text.delay_one_second, "ax"
    .thumb_func
delay_one_second:
    ldr     r0, =SECOND_DELAY
1:  subs    r0, #1
    bne     1b
    bx      lr
