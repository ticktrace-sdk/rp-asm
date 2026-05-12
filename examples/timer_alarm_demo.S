@ =============================================================================
@ examples/timer_alarm_demo.S - TIMER0 ALARM0 IRQ blink.
@
@ Demonstrates the full IRQ plumbing: install a handler with
@ nvic_install_handler, enable the alarm IRQ at the timer + NVIC level, then
@ go to wfi.  The ISR toggles GP25 and re-arms the alarm 100 ms in the future.
@
@ Build:    make build/timer_alarm_demo.uf2
@
@ Expected behaviour: LED toggles every 100 ms (~5 Hz blink) entirely from
@ the alarm ISR; the main loop never executes anything except wfi.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ ALARM_PERIOD_US, 100000           @ 100 ms

    .section .rodata.banner_alarm, "a"
banner_alarm:
    .asciz "rp-asm M3-B - alarm0 ISR blink\r\n"

@ ----------------------------------------------------------------------------
@ alarm0_isr - re-arm 100 ms in the future, clear IRQ flag, toggle LED.
@ Runs as the TIMER0_IRQ_0 handler (NVIC line 0).
@
@ Cycle budget: ~25 cycles end-to-end (3 calls + a few stores).
@ ----------------------------------------------------------------------------
    .section .text.alarm0_isr, "ax"
    .thumb_func
    .global  alarm0_isr
alarm0_isr:
    push    {r4, lr}

    @ Step 1: clear the alarm IRQ flag (W1C) before re-arming so we don't
    @ immediately re-fire on the same TIMELR value.
    movs    r0, #0                          @ timer_idx = 0
    movs    r1, #0                          @ alarm_idx = 0
    bl      alarm_clear_irq

    @ Step 2: schedule next alarm = TIMERAWL + 100 000 us
    bl      time_us_32                      @ r0 = now (lo)
    ldr     r1, =ALARM_PERIOD_US
    add     r0, r0, r1                      @ next = now + 100 000

    @ alarm_set(0, 0, next, 0)
    mov     r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set

    @ Step 3: visible side effect
    bl      gpio_led_toggle

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
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

    bl      timer_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    ldr     r0, =banner_alarm
    bl      uart0_puts

    @ ---- Install handler in vector table (NVIC line 0 = TIMER0_IRQ_0) -----
    movs    r0, #0
    ldr     r1, =alarm0_isr
    bl      nvic_install_handler

    @ ---- Enable the IRQ at the timer + NVIC -------------------------------
    movs    r0, #0                          @ timer_idx = 0
    movs    r1, #0                          @ alarm_idx = 0
    bl      alarm_enable_irq                @ INTE.ALARM0 = 1

    movs    r0, #0
    bl      nvic_enable_irq                 @ NVIC line 0 = TIMER0_IRQ_0

    @ ---- Schedule the first alarm 100 ms in the future --------------------
    bl      time_us_32
    ldr     r1, =ALARM_PERIOD_US
    add     r0, r0, r1
    mov     r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set

    @ ---- main idle: hand the CPU to the ISR -------------------------------
.Lidle:
    wfi
    b       .Lidle

@ ---- Bundle the M3-B driver objects into this image -----------------------
    .include "src/timer.S"
    .include "src/nvic.S"
