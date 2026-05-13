@ =============================================================================
@ examples/systick_usb_demo.S - SysTick verification via LED + USB CDC.
@
@ T4 hardware-verification fixture for src/systick.S using only the
@ on-board LED (GP25) and the USB device port.
@
@ SysTick is a Cortex-M core peripheral (not an NVIC line) at the
@ standard ARMv8-M address 0xE000E010.  It vectors through core
@ exception slot 15, not vec[16+irq], so we patch _ram_vectors[15]
@ directly here rather than via nvic_install_handler (which only knows
@ about the IRQ table at vec[16+]).
@
@ Wiring:
@   * SysTick runs from the processor clock (clk_sys = 150 MHz post-M2).
@     RVR = 15 000 000 - 1 -> 100 ms period (5 Hz LED toggle).
@   * ISR toggles GP25 + bumps systick_count + sets systick_pending.
@   * Main loop drains the pending flag and sends "stk N" via USB CDC.
@   * Independent "hb N" software heartbeat at ~500 ms via busy delay.
@
@ Expected on a Linux host:
@   make build/systick_usb_demo_flash.uf2
@   # BOOTSEL + drag onto the RP2350 drive
@   screen /dev/ttyACM0 115200
@   # expect: LED at ~5 Hz (rapid flicker)
@   # expect: "stk 1\r\n", "stk 2\r\n", ... 10 lines per second
@   #         interleaved with "hb N" every ~500 ms.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "systick.inc"
    .include "usb.inc"

    .equ SYSTICK_RVR_100MS_150MHZ, 15000000 - 1

    .section .data.systick_usb, "aw"
    .align   2
    .global  systick_pending
systick_pending:    .word 0
    .global  systick_count
systick_count:      .word 0

    .section .rodata.systick_usb, "a"
banner_uart:        .asciz "rp-asm M3-B - SysTick + USB CDC verification\r\n"
prefix_stk:         .asciz "stk "
prefix_hb:          .asciz "hb "
suffix_crlf:        .asciz "\r\n"

@ ----------------------------------------------------------------------------
@ systick_isr - core exception 15.  Toggles LED, bumps count + flag.
@ ----------------------------------------------------------------------------
    .section .text.systick_isr, "ax"
    .thumb_func
    .global  systick_isr
systick_isr:
    push    {r4, lr}
    bl      gpio_led_toggle
    ldr     r0, =systick_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    ldr     r0, =systick_pending
    movs    r1, #1
    str     r1, [r0]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ _put_uint_decimal(value) - send unsigned decimal to USB CDC.
@   r0 = value.  Clobbers r0-r3.  10-digit + NUL stack buffer.
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
    @ Clocks (150 MHz clk_sys, 48 MHz clk_usb)
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    ldr     r0, =banner_uart
    bl      uart0_puts

    @ USB CDC
    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ ---- Patch _ram_vectors[15] -> systick_isr ----------------------------
    @ SysTick is core exception 15.  nvic_install_handler is irq-only.
    ldr     r0, =0xE000ED08                       @ SCB_VTOR
    ldr     r0, [r0]
    ldr     r1, =systick_isr
    orr     r1, r1, #1                            @ Thumb bit
    str     r1, [r0, #(15 * 4)]                   @ vec[15] = systick_isr|1

    @ ---- Start SysTick @ 100 ms ------------------------------------------
    ldr     r0, =SYSTICK_RVR_100MS_150MHZ
    bl      systick_start_periodic

    @ ---- Diagnostic loop --------------------------------------------------
    movs    r4, #0                                @ hb counter
.Lloop:
    @ Drain SysTick pending
    ldr     r0, =systick_pending
    ldr     r1, [r0]
    cbz     r1, 1f
    movs    r1, #0
    str     r1, [r0]
    ldr     r0, =prefix_stk
    bl      cdc_puts
    ldr     r0, =systick_count
    ldr     r0, [r0]
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts
1:
    @ Software heartbeat every ~500 ms @ 150 MHz (25M cycles, 3-cycle body)
    ldr     r0, =25000000
2:  subs    r0, #1
    bne     2b

    ldr     r0, =prefix_hb
    bl      cdc_puts
    adds    r4, #1
    mov     r0, r4
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    b       .Lloop

    .include "src/systick.S"
    .include "src/nvic.S"
