@ =============================================================================
@ examples/data_usb_demo.S - ADC + TRNG + SHA256 verification via USB CDC.
@
@ Combined T4 fixture for the three "pure data" peripherals.  Each
@ iteration (~1 s) runs all three checks and emits a single CDC line per
@ peripheral:
@
@   adc temp=<raw 12-bit value>           (raw count, no calibration)
@   trng=<32-bit hex>
@   sha256 abc=<PASS|FAIL> got=<8 hex words>
@
@ SHA256 reference: NIST FIPS 180-4 vector for "abc":
@   H = ba7816bf 8f01cfea 414140de 5dae2223
@       b00361a3 96177a9c b410ff61 f20015ad
@ Our driver writes SUM0..SUM7 to memory; LE-reload gives back the same
@ integer.  Word-wise compare with the expected H values.
@
@ Verify:   flash, screen /dev/ttyACM0 115200.  Expect a fresh trio every
@           second; sha256 line says PASS; adc temp value somewhere in
@           ~1000..1500 raw counts at room temp; trng changes each line.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "adc.inc"
    .include "usb.inc"

    .section .data.data_usb_state, "aw"
    .align   2
iter_count: .word 0
digest_buf: .space 32

    .section .rodata.data_usb, "a"
    .align   2
banner_uart:    .asciz "rp-asm M5 - ADC + TRNG + SHA256 verification\r\n"

prefix_iter:    .asciz "--- iter "
prefix_adc:     .asciz "adc temp="
prefix_trng:    .asciz "trng=0x"
prefix_sha_pass:.asciz "sha256 abc=PASS got="
prefix_sha_fail:.asciz "sha256 abc=FAIL got="
suffix_crlf:    .asciz "\r\n"

@ Message to hash + expected digest (H0..H7 as 32-bit state words).
msg_abc:        .ascii "abc"
    .align 2

    .global expected_abc
expected_abc:
    .word 0xba7816bf
    .word 0x8f01cfea
    .word 0x414140de
    .word 0x5dae2223
    .word 0xb00361a3
    .word 0x96177a9c
    .word 0xb410ff61
    .word 0xf20015ad

@ ----------------------------------------------------------------------------
@ _put_uint_decimal(value)
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
@ _put_hex32(value)
@ ----------------------------------------------------------------------------
    .section .text._put_hex32, "ax"
    .thumb_func
_put_hex32:
    push    {r4, lr}
    sub     sp, sp, #12
    mov     r4, sp
    movs    r1, #0
    strb    r1, [r4, #8]
    movs    r2, #8
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
    add     sp, sp, #12
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

    @ USB CDC
    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ ---- ADC bring-up ----------------------------------------------------
    bl      adc_init
    movs    r0, #1
    bl      adc_set_temp_sensor_enabled
    movs    r0, #ADC_CH_TEMP                      @ = 8
    bl      adc_select_input

    @ ---- TRNG bring-up ---------------------------------------------------
    bl      trng_init

    @ ---- SHA256 bring-up -------------------------------------------------
    bl      sha256_init

.Liter_loop:
    @ --- iter N -------------------------------------------------------
    ldr     r0, =prefix_iter
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ --- ADC ----------------------------------------------------------
    ldr     r0, =prefix_adc
    bl      cdc_puts
    bl      adc_read
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ --- TRNG ---------------------------------------------------------
    ldr     r0, =prefix_trng
    bl      cdc_puts
    bl      trng_get_random_word
    bl      _put_hex32
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ --- SHA256("abc") ------------------------------------------------
    ldr     r0, =msg_abc
    movs    r1, #3
    ldr     r2, =digest_buf
    bl      sha256_compute

    @ Word-wise compare against expected_abc[0..7]
    ldr     r4, =digest_buf
    ldr     r5, =expected_abc
    movs    r6, #0                                @ pass flag (will set to 1 if mismatch)
    movs    r7, #0                                @ index
.Lsha_cmp:
    cmp     r7, #8
    bge     .Lsha_done
    lsls    r8, r7, #2
    ldr     r0, [r4, r8]
    ldr     r1, [r5, r8]
    cmp     r0, r1
    beq     1f
    movs    r6, #1                                @ mark fail
1:  adds    r7, #1
    b       .Lsha_cmp
.Lsha_done:

    cbz     r6, .Lsha_pass
    ldr     r0, =prefix_sha_fail
    b       1f
.Lsha_pass:
    ldr     r0, =prefix_sha_pass
1:  bl      cdc_puts
    @ Print all 8 words of the digest (LE-reloaded form)
    movs    r7, #0
.Lsha_dump:
    cmp     r7, #8
    bge     .Lsha_dump_done
    lsls    r8, r7, #2
    ldr     r0, [r4, r8]
    bl      _put_hex32
    adds    r7, #1
    b       .Lsha_dump
.Lsha_dump_done:
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ LED heartbeat: toggle each iteration
    bl      gpio_led_toggle

    @ ~1 second pause at 150 MHz
    ldr     r0, =50000000
2:  subs    r0, #1
    bne     2b
    b       .Liter_loop

    .include "src/nvic.S"
