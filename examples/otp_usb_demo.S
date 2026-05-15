@ =============================================================================
@ examples/otp_usb_demo.S - read factory OTP rows + report via USB CDC.
@
@ Reads:
@   CHIPID0..3       (rows 0..3)     64-bit chip-unique identifier
@   RANDID0..7       (rows 4..0xb)   128-bit private random identifier
@   FLASH_DEVINFO    (row 0x54)      info about the on-board flash chip
@
@ Prints once per second (one line):
@   chipid=XXXXXXXX_XXXXXXXX randid=XXXXXXXX_XXXXXXXX_XXXXXXXX_XXXXXXXX flash_devinfo=XXXX
@
@ All values are factory-programmed and don't change run-to-run, so
@ repeated lines should be identical - a basic sanity check that the
@ OTP read path is deterministic.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"

    .equ OTP_ROW_RANDID0,        4
    .equ OTP_ROW_FLASH_DEVINFO,  0x54

    .section .bss.otp_dst, "aw", %nobits
    .align   2
chipid_buf: .space 8                            @ CHIPID0..3 (4 halfwords)

    .section .data.otp_state, "aw"
    .align   2
iter_count: .word 0

    .section .rodata.otp_usb, "a"
banner_uart:    .asciz "rp-asm M7 - OTP factory data read\r\n"
prefix_chipid:  .asciz "chipid=0x"
mid_underscore: .asciz "_"
mid_randid:     .asciz " randid=0x"
mid_flashinfo:  .asciz " flash_devinfo=0x"
suffix_crlf:    .asciz "\r\n"

@ ----------------------------------------------------------------------------
@ _put_hex16(value) - send 4-digit hex (no 0x prefix).
@ Clobbers r0-r4.
@ ----------------------------------------------------------------------------
    .section .text._put_hex16, "ax"
    .thumb_func
_put_hex16:
    push    {r4, lr}
    sub     sp, sp, #8
    mov     r4, sp
    movs    r1, #0
    strb    r1, [r4, #4]                          @ NUL
    movs    r2, #4
1:  subs    r2, #1
    and     r1, r0, #0xF
    cmp     r1, #10
    blt     2f
    adds    r1, #('a' - 10)
    b       3f
2:  adds    r1, #'0'
3:  strb    r1, [r4, r2]
    lsrs    r0, r0, #4
    cmp     r2, #0
    bne     1b
    mov     r0, r4
    bl      cdc_puts
    add     sp, sp, #8
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

.Lloop:
    @ ---- CHIPID0..3 -> chipid_buf, then dump as two 16-bit hwords pairs ---
    ldr     r0, =chipid_buf
    bl      otp_read_chipid

    @ Print iter prefix
    ldr     r0, =prefix_chipid
    bl      cdc_puts

    @ chipid = CHIPID3_CHIPID2 (high 32) _ CHIPID1_CHIPID0 (low 32)
    ldr     r0, =chipid_buf
    ldrh    r0, [r0, #6]                          @ CHIPID3
    bl      _put_hex16
    ldr     r0, =chipid_buf
    ldrh    r0, [r0, #4]                          @ CHIPID2
    bl      _put_hex16
    ldr     r0, =mid_underscore
    bl      cdc_puts
    ldr     r0, =chipid_buf
    ldrh    r0, [r0, #2]                          @ CHIPID1
    bl      _put_hex16
    ldr     r0, =chipid_buf
    ldrh    r0, [r0, #0]                          @ CHIPID0
    bl      _put_hex16

    @ ---- RANDID0..7 (128 bits, rows 4..11, printed MS-first) -----------
    ldr     r0, =mid_randid
    bl      cdc_puts
    movs    r0, #(OTP_ROW_RANDID0 + 7)            @ row 11 (bits 127..112)
    bl      otp_read_row
    bl      _put_hex16
    movs    r0, #(OTP_ROW_RANDID0 + 6)            @ row 10 (bits 111..96)
    bl      otp_read_row
    bl      _put_hex16
    ldr     r0, =mid_underscore
    bl      cdc_puts
    movs    r0, #(OTP_ROW_RANDID0 + 5)            @ row 9  (bits  95..80)
    bl      otp_read_row
    bl      _put_hex16
    movs    r0, #(OTP_ROW_RANDID0 + 4)            @ row 8  (bits  79..64)
    bl      otp_read_row
    bl      _put_hex16
    ldr     r0, =mid_underscore
    bl      cdc_puts
    movs    r0, #(OTP_ROW_RANDID0 + 3)            @ row 7  (bits  63..48)
    bl      otp_read_row
    bl      _put_hex16
    movs    r0, #(OTP_ROW_RANDID0 + 2)            @ row 6  (bits  47..32)
    bl      otp_read_row
    bl      _put_hex16
    ldr     r0, =mid_underscore
    bl      cdc_puts
    movs    r0, #(OTP_ROW_RANDID0 + 1)            @ row 5  (bits  31..16)
    bl      otp_read_row
    bl      _put_hex16
    movs    r0, #OTP_ROW_RANDID0                  @ row 4  (bits  15..0 )
    bl      otp_read_row
    bl      _put_hex16

    @ ---- FLASH_DEVINFO --------------------------------------------------
    ldr     r0, =mid_flashinfo
    bl      cdc_puts
    movw    r0, #OTP_ROW_FLASH_DEVINFO
    bl      otp_read_row
    bl      _put_hex16

    ldr     r0, =suffix_crlf
    bl      cdc_puts

    bl      gpio_led_toggle

    @ ~1 s pause
    ldr     r0, =50000000
3:  subs    r0, #1
    bne     3b
    b       .Lloop

    .include "src/nvic.S"
