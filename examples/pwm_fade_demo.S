@ =============================================================================
@ examples/pwm_fade_demo.S - 4-second triangle fade on GP15 (slice 7, ch B).
@
@ Why GP15: on the RP2350 PWM mapping
@     slice = ((pin >> 1) & 7) | ((pin >> 4) & 8)
@     chan  = pin & 1
@   GP15 -> slice 7, channel B.  Pin available on the Pico 2 header.
@   GP25 (the on-board LED) maps to slice 4 ch B and is driven by gpio_led_*
@   from src/gpio.S; we leave that pin untouched here.
@
@ At clk_sys = 150 MHz we want a fade fast enough to look smooth (~250 Hz
@ refresh) but with enough resolution that a single LSB step is invisible:
@   PWM_FREQ = 150e6 / (DIV.int * (TOP+1)) = 150e6 / (6 * 100) = 250 kHz
@ -> 250000 / 100 (TOP wraps) = 2.5 kHz wrap rate.  Increment one level per
@ wrap and we sweep 0..100 in 40 ms; 4 seconds = 100 cycles of full fade.
@
@ In this demo we fade purely in software (no IRQ): a busy loop steps the
@ duty cycle one notch every ~20 ms, sweeping up then back down.
@
@ Build:    make build/pwm_fade_demo.uf2
@ Verify:   115200 8N1 prints "pwm fade demo @ GP15 (slice 7B)\r\n" once;
@           GP15 fades in/out forever.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Pull in the PWM driver (cwd is repo root when make calls us).
    .include "src/pwm.S"

    .equ FADE_PIN,          15
    .equ FADE_SLICE,        PWM_SLICE_FOR_GP15      @ = 7
    .equ FADE_CHAN,         PWM_CHAN_FOR_GP15       @ = 1 (B)
    .equ FADE_TOP,          100                     @ 1% duty resolution
    .equ FADE_DIV_INT,      6                       @ -> 250 kHz tick

    @ Inner busy-loop count between duty-cycle steps.  At 150 MHz with a
    @ 3-cycle inner body (subs + bne) one count = 20 ns; 1_000_000 = 20 ms.
    .equ FADE_STEP_DELAY,   1000000

    .section .rodata.banner_pwm_fade, "a"
banner:
    .asciz "pwm fade demo @ GP15 (slice 7B)\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clock tree -------------------------------------------------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- UART for the banner ---------------------------------------------
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner
    bl      uart0_puts

    @ ---- PWM bring-up ----------------------------------------------------
    bl      pwm_init                            @ release PWM block from reset

    movs    r0, #FADE_PIN
    bl      pwm_set_gpio_function

    movs    r0, #FADE_SLICE
    movs    r1, #FADE_DIV_INT
    bl      pwm_set_clkdiv_int

    movs    r0, #FADE_SLICE
    movs    r1, #FADE_TOP
    bl      pwm_set_wrap

    @ Initial level = 0 (LED off)
    movs    r0, #FADE_SLICE
    movs    r1, #FADE_CHAN
    movs    r2, #0
    bl      pwm_set_chan_level

    @ Enable the slice
    movs    r0, #FADE_SLICE
    movs    r1, #1
    bl      pwm_set_enabled

    @ ---- Triangle-fade forever -------------------------------------------
.Lfade_loop:
    @ Up sweep: level 0 -> FADE_TOP
    movs    r4, #0
.Lup:
    movs    r0, #FADE_SLICE
    movs    r1, #FADE_CHAN
    mov     r2, r4
    bl      pwm_set_chan_level

    ldr     r5, =FADE_STEP_DELAY
1:  subs    r5, #1
    bne     1b

    adds    r4, #1
    cmp     r4, #FADE_TOP
    ble     .Lup

    @ Down sweep: level FADE_TOP -> 0
    movs    r4, #FADE_TOP
.Ldown:
    movs    r0, #FADE_SLICE
    movs    r1, #FADE_CHAN
    mov     r2, r4
    bl      pwm_set_chan_level

    ldr     r5, =FADE_STEP_DELAY
2:  subs    r5, #1
    bne     2b

    subs    r4, #1
    bge     .Ldown

    b       .Lfade_loop
