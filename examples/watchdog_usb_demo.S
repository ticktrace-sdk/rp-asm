@ =============================================================================
@ examples/watchdog_usb_demo.S - watchdog kick + intentional reset.
@
@ T4 fixture proving end-to-end watchdog functionality with only LED +
@ USB CDC observables.  Demo cycle (~5 s):
@
@   1. Boot, bring up clocks + USB CDC (banner: "wd boot N").
@   2. Enable the watchdog with a 2 s timeout.
@   3. Main loop kicks the watchdog every 200 ms and prints
@        "wd kick K/10" (k = 1..10, LED toggle each kick)
@   4. After 10 kicks STOP kicking, print "wd STARVING - resetting in <= 2s"
@   5. Watchdog times out, chip resets.  USB drops + re-enumerates;
@      the boot counter (kept across reset via WATCHDOG_SCRATCH0)
@      increments.
@
@ A successful run shows the host:
@   - sees ttyACM0 enumerate
@   - prints "wd boot 1", "wd kick 1..10", "wd STARVING ..."
@   - sees a USB disconnect about ~2 s later
@   - sees ttyACM0 re-enumerate, "wd boot 2", and the loop repeats
@
@ This proves: watchdog_enable, watchdog_feed prevents reset,
@ watchdog actually triggers reset on starvation, the WATCHDOG block
@ comes out of reset correctly post-watchdog-reset.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    @ WATCHDOG_BASE + offsets so we can keep a boot counter across reset.
    .equ WD_BASE,         0x400d8000
    .equ WD_SCRATCH0,     0x0C            @ scratch reg 0 (preserved across reset)
    .equ WD_TIMEOUT_US,   2000000         @ 2 seconds

    .section .data.wd_usb_state, "aw"
    .align   2
kick_count: .word 0

    .section .rodata.wd_usb, "a"
banner_uart:    .asciz "rp-asm M2 - watchdog kick/timeout verification\r\n"
prefix_boot:    .asciz "wd boot "
prefix_kick:    .asciz "wd kick "
suffix_of_10:   .asciz "/10\r\n"
msg_starving:   .asciz "wd STARVING - waiting for natural timeout (<= 3s)\r\n"
msg_trigger:    .asciz "wd FORCED TRIGGER (CTRL bit 31)\r\n"

@ ----------------------------------------------------------------------------
@ _put_uint_decimal
@ ----------------------------------------------------------------------------
    .section .text._put_uint_decimal, "ax"
    .thumb_func
_put_uint_decimal:
    push    {r4, r5, r6, lr}
    sub     sp, sp, #12
    mov     r4, sp
    adds    r4, #11
    movs    r5, #0
    strb    r5, [r4]
    movs    r6, #10
    cbnz    r0, 1f
    subs    r4, #1
    movs    r5, #'0'
    strb    r5, [r4]
    b       2f
1:  udiv    r2, r0, r6
    mls     r3, r2, r6, r0
    adds    r3, #'0'
    subs    r4, #1
    strb    r3, [r4]
    mov     r0, r2
    cmp     r0, #0
    bne     1b
2:  mov     r0, r4
    bl      cdc_puts
    add     sp, sp, #12
    pop     {r4, r5, r6, pc}

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
    bl      watchdog_disable                      @ ensure clean slate

    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner_uart
    bl      uart0_puts

    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ Wait until the host has issued SET_CONFIGURATION (usb_configured = 1)
    @ so our first CDC writes actually reach a listener.  Cap the wait at
    @ ~5 s so we don't hang forever if no host is attached.
    ldr     r4, =750000000                        @ 5 s at 150 MHz, 3-cycle body
.Lwait_enum:
    ldr     r0, =usb_configured
    ldr     r1, [r0]
    cbnz    r1, .Lenumerated
    subs    r4, #1
    bne     .Lwait_enum
.Lenumerated:

    @ ---- Read + bump SCRATCH0 boot counter (preserved across WD reset) ---
    ldr     r0, =WD_BASE
    ldr     r1, [r0, #WD_SCRATCH0]
    adds    r1, #1
    str     r1, [r0, #WD_SCRATCH0]
    ldr     r0, =prefix_boot
    bl      cdc_puts
    mov     r0, r1
    bl      _put_uint_decimal
    movs    r2, #'\r'
    movs    r3, #'\n'
    @ short crlf via two cdc_putc calls would need separate helper; use cdc_puts trick
    @ -- just print "\r\n" via cdc_puts of a 2-char rodata string.
    ldr     r0, =msg_crlf
    bl      cdc_puts

    @ ---- Wire WDOG to actually reset something --------------------------
    @ PSM_WDSEL (PSM_BASE + 0x08) selects which subsystems get reset when
    @ the watchdog fires.  Default is 0 -> watchdog times out but resets
    @ nothing visible.  Pico-sdk's pattern: set everything except ROSC
    @ (bit 2) and XOSC (bit 3) so the clocks survive the reset.
    ldr     r0, =0x40018008                       @ PSM_WDSEL
    ldr     r1, =0x01fffff3                       @ all 25 bits MINUS bits 2 + 3
    str     r1, [r0]

    @ ---- Enable watchdog: 2 s timeout ------------------------------------
    ldr     r0, =WD_TIMEOUT_US
    bl      watchdog_enable

    @ ---- Kick + report 10 times -----------------------------------------
    movs    r4, #0
.Lkick_loop:
    adds    r4, #1
    ldr     r5, =kick_count
    str     r4, [r5]

    bl      watchdog_feed
    bl      gpio_led_toggle

    ldr     r0, =prefix_kick
    bl      cdc_puts
    mov     r0, r4
    bl      _put_uint_decimal
    ldr     r0, =suffix_of_10
    bl      cdc_puts

    @ 200 ms busy delay at 150 MHz (3-cycle inner body, 10M iterations)
    ldr     r0, =10000000
2:  subs    r0, #1
    bne     2b

    cmp     r4, #10
    blt     .Lkick_loop

    @ ---- Starve the watchdog (let it time out naturally) ---------------
    ldr     r0, =msg_starving
    bl      cdc_puts

    @ ~3 s busy wait to give the watchdog ample time to fire on its own.
    ldr     r0, =450000000
.Lstarve_wait:
    subs    r0, #1
    bne     .Lstarve_wait

    @ Belt-and-suspenders: if natural timeout didn't reset us, force a
    @ reset via CTRL.TRIGGER (bit 31 = immediate watchdog reset).
    ldr     r0, =msg_trigger
    bl      cdc_puts
    ldr     r0, =0x400d8000                       @ WATCHDOG_BASE
    movs    r1, #1
    lsls    r1, #31
    str     r1, [r0]                              @ CTRL = TRIGGER

.Lstarve:
    wfi
    b       .Lstarve

@ ----------------------------------------------------------------------------
@ Local short \r\n string (separate symbol so we can reuse cdc_puts).
@ ----------------------------------------------------------------------------
    .section .rodata.wd_usb_crlf, "a"
msg_crlf:       .asciz "\r\n"

    .include "src/nvic.S"
