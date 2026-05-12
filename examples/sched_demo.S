@ =============================================================================
@ sched_demo.S - NVIC-priority kernel demo, three soft tasks at three priorities
@
@ Tasks:
@   T_BLINK  prio 0 (highest)  toggle GP25 LED
@   T_TICK   prio 1            print "tick\r\n" over UART0
@   T_HEAVY  prio 2 (lowest)   busy-work that proves T_BLINK preempts it
@
@ Triggers:
@   TIMER0 ALARM0 ISR fires every 100 ms  -> re-arm + task_post(T_BLINK)
@   TIMER0 ALARM1 ISR fires every 1000 ms -> re-arm + task_post(T_TICK)
@                                            + task_post(T_HEAVY) to demo preemption
@
@ Run this on a real Pico 2: LED blinks 5 Hz, UART prints "tick" once a
@ second.  Hook a logic analyser on GP25 + GP24 (we toggle GP24 inside
@ T_HEAVY to make the preemption visible).
@ =============================================================================

    .include "sched.inc"
    .include "src/nvic.S"
    .include "src/timer.S"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    @ Task IDs
    .equ T_BLINK, 0
    .equ T_TICK,  1
    .equ T_HEAVY, 2

    @ NVIC IRQ numbers for TIMER0_IRQ_0 and TIMER0_IRQ_1
    .equ TIMER0_IRQ_0, 0
    .equ TIMER0_IRQ_1, 1

    .equ ALARM_BLINK_US, 100000
    .equ ALARM_TICK_US, 1000000

    .section .rodata.demo, "a"
banner: .asciz "sched_demo: T_BLINK@p0  T_TICK@p1  T_HEAVY@p2\r\n"
tick:   .asciz "tick\r\n"

    .section .bss.demo, "aw", %nobits
    .align 2
heavy_counter: .word 0

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ Standard bring-up
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    @ GP24 as a probe pin for the logic analyser to see T_HEAVY pulses.
    movs    r0, #24
    movs    r1, #1
    bl      gpio_init                       @ if your gpio.S exposes it; else fall back
    movs    r0, #24
    movs    r1, #1
    bl      gpio_set_dir

    ldr     r0, =banner
    bl      uart0_puts

    @ ---- Scheduler init ---------------------------------------------------
    bl      sched_init

    @ Register soft tasks
    movs    r0, #T_BLINK
    ldr     r1, =t_blink_body
    movs    r2, #0x00                       @ highest priority (numeric 0)
    bl      task_create

    movs    r0, #T_TICK
    ldr     r1, =t_tick_body
    movs    r2, #0x40                       @ medium (bits[7:6])
    bl      task_create

    movs    r0, #T_HEAVY
    ldr     r1, =t_heavy_body
    movs    r2, #0x80                       @ lowest
    bl      task_create

    @ ---- Wire TIMER0 ALARM0 + ALARM1 to fire the soft tasks ---------------
    @ TIMER0 is brought up by tick_init.  We install our own ISRs in the
    @ NVIC vectors for IRQ 0 (ALARM0) and IRQ 1 (ALARM1).
    ldr     r0, =timer0_alarm0_isr
    movs    r1, #TIMER0_IRQ_0
    bl      nvic_install_handler
    movs    r0, #TIMER0_IRQ_0
    bl      nvic_enable_irq

    ldr     r0, =timer0_alarm1_isr
    movs    r1, #TIMER0_IRQ_1
    bl      nvic_install_handler
    movs    r0, #TIMER0_IRQ_1
    bl      nvic_enable_irq

    @ Enable INTE bits 0 and 1 on TIMER0
    ldr     r0, =0x400b0000 + 0x38          @ TIMER0 INTE
    movs    r1, #0x3
    str     r1, [r0]

    @ Schedule the first alarms
    bl      time_us_32
    ldr     r2, =ALARM_BLINK_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set

    bl      time_us_32
    ldr     r2, =ALARM_TICK_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #1
    movs    r3, #0
    bl      alarm_set

    @ ---- Off we go --------------------------------------------------------
    b       sched_run

@ -----------------------------------------------------------------------------
@ Soft task bodies — each runs as an NVIC handler, returns when done.
@ -----------------------------------------------------------------------------

    .section .text.t_blink_body, "ax"
    .thumb_func
    .global  t_blink_body
t_blink_body:
    push    {lr}
    bl      gpio_led_toggle
    pop     {pc}

    .section .text.t_tick_body, "ax"
    .thumb_func
    .global  t_tick_body
t_tick_body:
    push    {lr}
    ldr     r0, =tick
    bl      uart0_puts
    pop     {pc}

    @ T_HEAVY: ~10000-iter spin, with GP24 high while running so a logic
    @ analyser can see T_BLINK preempt us.  Demonstrates run-to-completion
    @ at our priority level + preemption from higher priority.
    .section .text.t_heavy_body, "ax"
    .thumb_func
    .global  t_heavy_body
t_heavy_body:
    push    {r4, lr}
    @ GP24 high
    movs    r1, #(1 << 24)
    ldr     r0, =0xd0000000 + 0x18          @ SIO_GPIO_OUT_SET
    str     r1, [r0]

    ldr     r4, =10000
1:  subs    r4, #1
    bne     1b

    @ GP24 low
    movs    r1, #(1 << 24)
    ldr     r0, =0xd0000000 + 0x20          @ SIO_GPIO_OUT_CLR
    str     r1, [r0]
    pop     {r4, pc}

@ -----------------------------------------------------------------------------
@ Hardware ISRs — minimal "post the soft task and rearm" pattern.
@ -----------------------------------------------------------------------------

    .section .text.timer0_alarm0_isr, "ax"
    .thumb_func
    .global  timer0_alarm0_isr
timer0_alarm0_isr:
    push    {lr}
    @ Ack alarm 0
    movs    r0, #0
    movs    r1, #0
    bl      alarm_clear_irq
    @ Re-arm 100 ms from now
    bl      time_us_32
    ldr     r2, =ALARM_BLINK_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #0
    movs    r3, #0
    bl      alarm_set
    @ Post the soft task
    movs    r0, #T_BLINK
    bl      task_post
    pop     {pc}

    .section .text.timer0_alarm1_isr, "ax"
    .thumb_func
    .global  timer0_alarm1_isr
timer0_alarm1_isr:
    push    {lr}
    movs    r0, #0
    movs    r1, #1
    bl      alarm_clear_irq
    bl      time_us_32
    ldr     r2, =ALARM_TICK_US
    add     r2, r2, r0
    movs    r0, #0
    movs    r1, #1
    movs    r3, #0
    bl      alarm_set
    movs    r0, #T_TICK
    bl      task_post
    movs    r0, #T_HEAVY
    bl      task_post
    pop     {pc}
