@ =============================================================================
@ gpio.S - LED on GPIO25 (Raspberry Pi Pico 2)
@
@ After RP2350 reset, every pad starts isolated (ISO=1) and output-disabled
@ (OD=1).  To drive an LED we must:
@   1. Clear ISO+OD on the pad.
@   2. Point the GPIO function mux at SIO (FUNCSEL=5).
@   3. Drive the SIO output-enable bit for the pin.
@
@ All writes use atomic SET/CLR aliases - no read-modify-write hazards if an
@ ISR ever touches a sibling pad.
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ LED_PIN, 25

@ ----------------------------------------------------------------------------
@ gpio_led_init - configure GPIO25 as a SIO-driven push-pull output, low.
@ Clobbers: r0-r3.  ~10 stores; ~30 cycles end-to-end.
@ ----------------------------------------------------------------------------
    .section .text.gpio_led_init, "ax"
    .thumb_func
    .global  gpio_led_init
gpio_led_init:
    @ ---- PADS_BANK0: clear ISO and OD on the pad ---------------------------
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (LED_PIN * PADS_BANK0_PAD_STRIDE)
    movs    r1, #(PADS_ISO | PADS_OD) >> 6      @ keep operand 8-bit clean...
    lsls    r1, #6                              @ ...then shift back: r1 = 0x180
    str     r1, [r0]

    @ ---- IO_BANK0: select SIO function on GPIO25 ---------------------------
    ldr     r0, =IO_BANK0_BASE + 4 + (LED_PIN * IO_BANK0_GPIO_CTRL_STRIDE)
    movs    r1, #GPIO_FUNC_SIO
    str     r1, [r0]

    @ ---- SIO: drive low first, then enable output --------------------------
    movs    r2, #1
    lsls    r2, #LED_PIN                        @ r2 = 1 << 25

    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r2, [r0]
    ldr     r0, =SIO_BASE + SIO_GPIO_OE_SET
    str     r2, [r0]

    bx      lr

@ ----------------------------------------------------------------------------
@ gpio_led_toggle - one XOR store (2 cycles).
@ ----------------------------------------------------------------------------
    .section .text.gpio_led_toggle, "ax"
    .thumb_func
    .global  gpio_led_toggle
gpio_led_toggle:
    movs    r1, #1
    lsls    r1, #LED_PIN
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_XOR
    str     r1, [r0]
    bx      lr
