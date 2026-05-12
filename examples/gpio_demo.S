@ =============================================================================
@ examples/gpio_demo.S - 3-LED bar pattern across GPIO22/23/24.
@
@ Cycles an 8-step Knight Rider-ish bar across three pins so a logic analyser
@ can verify gpio_init / gpio_set_dir / gpio_put / gpio_toggle from the new
@ M3 driver.  Avoids GPIO25 which is taken by the on-board LED + main blinky.
@
@ Boot path:
@   1. Bring up the clock tree (so 1ms delay below is meaningful).
@   2. Initialise GP22, GP23, GP24 as SIO outputs.
@   3. Loop forever stepping a small pattern table; 1 step per ~1 ms.
@
@ Step pattern (bit 0 = GP22, bit 1 = GP23, bit 2 = GP24):
@   0: 001    1: 010    2: 100    3: 010
@   4: 001    5: 011    6: 111    7: 000
@
@ At 150 MHz the inner busy loop = 50_000 iterations * 3 cycles = 1 ms.
@
@ Build:    make examples/gpio_demo.uf2
@ Flash:    drop build/gpio_demo.uf2 onto BOOTSEL
@ Verify:   logic analyser on GP22-24, expect ~125 Hz step rate.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ DELAY_1MS_150MHZ, 50000

    .equ PIN_A, 22
    .equ PIN_B, 23
    .equ PIN_C, 24

    .section .rodata.steps, "a"
    .align 2
steps:
    .byte 0b001
    .byte 0b010
    .byte 0b100
    .byte 0b010
    .byte 0b001
    .byte 0b011
    .byte 0b111
    .byte 0b000
steps_end:
    .equ NUM_STEPS, steps_end - steps

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clock tree bring-up (matches clocks_demo.S order) -----------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- Initialise GP22, GP23, GP24 as outputs --------------------------
    movs    r0, #PIN_A
    bl      gpio_init
    movs    r0, #PIN_A
    movs    r1, #1
    bl      gpio_set_dir

    movs    r0, #PIN_B
    bl      gpio_init
    movs    r0, #PIN_B
    movs    r1, #1
    bl      gpio_set_dir

    movs    r0, #PIN_C
    bl      gpio_init
    movs    r0, #PIN_C
    movs    r1, #1
    bl      gpio_set_dir

    @ ---- Step loop -------------------------------------------------------
    movs    r4, #0                          @ r4 = step index
.Lloop:
    ldr     r5, =steps
    ldrb    r5, [r5, r4]                    @ r5 = step pattern byte

    @ Drive GP22 from bit 0
    movs    r0, #PIN_A
    movs    r1, r5
    movs    r2, #1
    ands    r1, r2
    bl      gpio_put

    @ Drive GP23 from bit 1
    movs    r0, #PIN_B
    movs    r1, r5
    lsrs    r1, #1
    movs    r2, #1
    ands    r1, r2
    bl      gpio_put

    @ Drive GP24 from bit 2
    movs    r0, #PIN_C
    movs    r1, r5
    lsrs    r1, #2
    movs    r2, #1
    ands    r1, r2
    bl      gpio_put

    @ Toggle GP25 too as a heartbeat (so the main blinky LED stays alive)
    movs    r0, #25
    bl      gpio_toggle

    @ ~1 ms delay
    ldr     r0, =DELAY_1MS_150MHZ
1:  subs    r0, #1
    bne     1b

    adds    r4, #1
    cmp     r4, #NUM_STEPS
    blo     .Lloop
    movs    r4, #0
    b       .Lloop
