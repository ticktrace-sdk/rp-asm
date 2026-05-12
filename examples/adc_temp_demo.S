@ =============================================================================
@ adc_temp_demo.S - read on-die temperature sensor every ~500 ms over UART
@
@ Outputs raw ADC counts (0..4095).  Convert to °C using:
@   V = 3.3 * raw / 4095
@   T_C = 27 - (V - 0.706) / 0.001721
@ done off-board to keep the firmware compiler-free.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .rodata.demo, "a"
banner:
    .asciz "adc temp sensor:\r\n"
prefix:
    .asciz "raw="
nl:
    .asciz "\r\n"
hex_digits:
    .ascii "0123456789abcdef"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    bl      adc_init
    movs    r0, #1
    bl      adc_set_temp_sensor_enabled
    movs    r0, #8                  @ temp sensor on channel 8
    bl      adc_select_input

    ldr     r0, =banner
    bl      uart0_puts

.Lloop:
    bl      adc_read                @ r0 = raw 12-bit value

    @ Print "raw=XXXX\r\n"
    push    {r0}
    ldr     r0, =prefix
    bl      uart0_puts
    pop     {r0}
    bl      print_u16_hex
    ldr     r0, =nl
    bl      uart0_puts

    bl      gpio_led_toggle

    @ ~250 ms at 150 MHz (delay loop, 3-cycle body)
    ldr     r0, =12500000
1:  subs    r0, #1
    bne     1b
    b       .Lloop

@ -----------------------------------------------------------------------------
@ print_u16_hex(r0=value) - prints 4 hex digits via uart0
@ -----------------------------------------------------------------------------
    .thumb_func
print_u16_hex:
    push    {r4, r5, r6, lr}
    mov     r4, r0
    ldr     r5, =hex_digits
    movs    r6, #12
1:  mov     r0, r4
    lsrs    r0, r6
    and     r0, #0xF
    ldrb    r0, [r5, r0]
    movs    r1, r0
    movs    r0, #0
    bl      uart_putc_blocking
    subs    r6, #4
    bge     1b
    pop     {r4, r5, r6, pc}
