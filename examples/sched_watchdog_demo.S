@ =============================================================================
@ sched_watchdog_demo.S — scheduler + watchdog as a deadman's switch.
@
@ Setup:
@   - Watchdog armed with a 200 ms timeout.
@   - High-priority task T_FEED feeds the watchdog every 100 ms.
@   - Medium-priority task T_HEARTBEAT prints "alive\r\n" every 1 s.
@   - GP25 LED toggles inside T_FEED so you can see liveness.
@
@ Failure modes the watchdog catches:
@   - T_FEED never runs (CPU stuck in lower-prio infinite loop)  -> reset
@   - Whole program crashes anywhere  -> reset after 200 ms
@
@ On a real Pico 2, after flashing you should see steady LED at 5 Hz and
@ "alive" once a second over UART0.  Unplug-and-replug or BOOTSEL to
@ re-flash, and the watchdog still keeps things going.
@
@ To DEMONSTRATE the safety net: comment out the `bl watchdog_feed` line
@ in t_feed_body, re-flash, and watch the device reset every 200 ms
@ (LED stops blinking, UART output stops, then the demo starts over).
@ =============================================================================

    .include "sched.inc"
    .include "src/nvic.S"
    .include "src/timer.S"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Task IDs
    .equ T_FEED,      0       @ highest priority — never miss a feed
    .equ T_HEARTBEAT, 1

    @ TIMER0 alarm slots
    .equ ALARM_FEED,      0
    .equ ALARM_HEARTBEAT, 1
    .equ NVIC_TIMER0_IRQ_0, 0
    .equ NVIC_TIMER0_IRQ_1, 1

    .equ FEED_PERIOD_US,      100000   @ 100 ms
    .equ HEARTBEAT_PERIOD_US, 1000000  @ 1 s
    .equ WDG_TIMEOUT_US,      200000   @ 200 ms — must be > FEED_PERIOD_US

    .section .rodata.demo, "a"
banner:    .asciz "sched_watchdog_demo - 200ms wdg, 100ms feed, 1s heartbeat\r\n"
alive:     .asciz "alive\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ Standard clock + UART bring-up
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    ldr     r0, =banner
    bl      uart0_puts

    @ Arm watchdog
    ldr     r0, =WDG_TIMEOUT_US
    bl      watchdog_enable

    @ ---- Scheduler -------------------------------------------------------
    bl      sched_init

    movs    r0, #T_FEED
    ldr     r1, =t_feed_body
    movs    r2, #0x00                         @ highest
    bl      task_create

    movs    r0, #T_HEARTBEAT
    ldr     r1, =t_heartbeat_body
    movs    r2, #0x80                         @ low
    bl      task_create

    @ Hardware ISRs for the two alarms
    ldr     r0, =timer0_alarm0_isr
    movs    r1, #NVIC_TIMER0_IRQ_0
    bl      nvic_install_handler
    movs    r0, #NVIC_TIMER0_IRQ_0
    bl      nvic_enable_irq

    ldr     r0, =timer0_alarm1_isr
    movs    r1, #NVIC_TIMER0_IRQ_1
    bl      nvic_install_handler
    movs    r0, #NVIC_TIMER0_IRQ_1
    bl      nvic_enable_irq

    @ Enable INTE bits 0 and 1 on TIMER0
    ldr     r0, =0x400b0000 + 0x38
    movs    r1, #0x3
    str     r1, [r0]

    @ First-fire arming
    bl      time_us_32
    ldr     r2, =FEED_PERIOD_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #ALARM_FEED
    movs    r3, #0
    bl      alarm_set

    bl      time_us_32
    ldr     r2, =HEARTBEAT_PERIOD_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #ALARM_HEARTBEAT
    movs    r3, #0
    bl      alarm_set

    b       sched_run

@ -----------------------------------------------------------------------------
@ Tasks
@ -----------------------------------------------------------------------------

    .section .text.t_feed_body, "ax"
    .thumb_func
    .global  t_feed_body
t_feed_body:
    push    {lr}
    bl      watchdog_feed                     @ <-- the deadman switch
    bl      gpio_led_toggle                   @ visible liveness
    pop     {pc}

    .section .text.t_heartbeat_body, "ax"
    .thumb_func
    .global  t_heartbeat_body
t_heartbeat_body:
    push    {lr}
    ldr     r0, =alive
    bl      uart0_puts
    pop     {pc}

@ -----------------------------------------------------------------------------
@ Hardware ISRs - re-arm + post the soft task.
@ -----------------------------------------------------------------------------

    .section .text.timer0_alarm0_isr, "ax"
    .thumb_func
    .global  timer0_alarm0_isr
timer0_alarm0_isr:
    push    {lr}
    movs    r0, #0
    movs    r1, #ALARM_FEED
    bl      alarm_clear_irq
    bl      time_us_32
    ldr     r2, =FEED_PERIOD_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #ALARM_FEED
    movs    r3, #0
    bl      alarm_set
    movs    r0, #T_FEED
    bl      task_post
    pop     {pc}

    .section .text.timer0_alarm1_isr, "ax"
    .thumb_func
    .global  timer0_alarm1_isr
timer0_alarm1_isr:
    push    {lr}
    movs    r0, #0
    movs    r1, #ALARM_HEARTBEAT
    bl      alarm_clear_irq
    bl      time_us_32
    ldr     r2, =HEARTBEAT_PERIOD_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #ALARM_HEARTBEAT
    movs    r3, #0
    bl      alarm_set
    movs    r0, #T_HEARTBEAT
    bl      task_post
    pop     {pc}
