@ =============================================================================
@ examples/dma_usb_demo.S - DMA mem-to-mem verification via LED + USB CDC.
@
@ T4 hardware-verification fixture for src/dma.S using only the LED
@ and USB CDC.  Every ~1 s:
@
@   1. Re-fill the destination buffer with 0xCAFEBABE (sentinel).
@   2. DMA channel 0 copies 256 words (1 KiB) from src_pattern[] to
@      dst_buf[] using DMA_CTRL_MEM2MEM_WORD.
@   3. Spin on BUSY until the channel finishes.
@   4. Word-wise compare; report:
@        dma OK words=256 iter=N\r\n         (LED solid on)
@        dma FAIL off=K exp=X got=Y\r\n      (LED rapid flicker)
@
@ Source pattern is generated in startup: src_pattern[i] = 0xDEADBEEF ^ i,
@ chosen so each word is unique and the high half makes scope/probe
@ inspection of DPRAM dumps trivially readable.
@
@ Build:    make build/dma_usb_demo_flash.uf2
@ Verify:   screen /dev/ttyACM0 115200  --> "dma OK words=256 iter=N"
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "dma.inc"
    .include "usb.inc"

    .equ COPY_WORDS,        256                       @ 1 KiB
    .equ DST_FILL_SENTINEL, 0xCAFEBABE
    .equ SRC_SEED,          0xDEADBEEF

    .section .bss.dma_usb_dst, "aw", %nobits
    .align   2
    .global  dst_buf
dst_buf:
    .space   COPY_WORDS * 4

    .section .data.dma_usb_state, "aw"
    .align   2
iter_count: .word 0

    .section .rodata.dma_usb_src, "a"
    .align   2
    .global  src_pattern
src_pattern:
    .rept COPY_WORDS
    .word SRC_SEED ^ (. - src_pattern) / 4
    .endr
src_pattern_end:

    .section .rodata.dma_usb, "a"
banner_uart: .asciz "rp-asm M3-C - DMA mem2mem + USB CDC verification\r\n"
prefix_ok:   .asciz "dma OK words="
mid_iter:    .asciz " iter="
prefix_fail: .asciz "dma FAIL off="
mid_exp:     .asciz " exp="
mid_got:     .asciz " got="
suffix_crlf: .asciz "\r\n"

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
@ _put_hex32(value) - send 8-digit hex (no 0x prefix) over CDC.
@ Clobbers r0-r3.
@ ----------------------------------------------------------------------------
    .section .text._put_hex32, "ax"
    .thumb_func
_put_hex32:
    push    {r4, r5, lr}
    sub     sp, sp, #12
    mov     r4, sp
    movs    r1, #0
    strb    r1, [r4, #8]                          @ NUL terminator at index 8
    movs    r2, #8                                @ 8 nibbles
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
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ _led_on / _led_off / _fail_blink
@ ----------------------------------------------------------------------------
    .section .text._led, "ax"
    .thumb_func
_led_on:
    movs    r1, #1
    lsls    r1, #25
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_SET
    str     r1, [r0]
    bx      lr

    .thumb_func
_led_off:
    movs    r1, #1
    lsls    r1, #25
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r1, [r0]
    bx      lr

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

    @ DMA out of reset
    bl      dma_init

.Liter_loop:
    @ ---- 1. Fill dst with sentinel ----------------------------------------
    ldr     r0, =dst_buf
    ldr     r1, =DST_FILL_SENTINEL
    movs    r2, #COPY_WORDS
1:  str     r1, [r0], #4
    subs    r2, #1
    bne     1b

    @ ---- 2. Configure + trigger DMA channel 0 -----------------------------
    @ dma_channel_configure(ch=0, ctrl=MEM2MEM_WORD, read=src, write=dst,
    @                       count=COPY_WORDS, trigger=1)
    movs    r0, #0                                @ channel 0
    ldr     r1, =DMA_CTRL_MEM2MEM_WORD
    ldr     r2, =src_pattern
    ldr     r3, =dst_buf
    movs    r4, #COPY_WORDS                       @ count (stack arg 1)
    movs    r5, #1                                @ trigger (stack arg 2)
    push    {r4, r5}
    bl      dma_channel_configure
    add     sp, sp, #8

    @ ---- 3. Wait for completion -------------------------------------------
    movs    r0, #0
    bl      dma_channel_wait_for_finish

    @ ---- 4. Word-wise compare ---------------------------------------------
    @ r4 = current word index, r5 = src_pattern base, r6 = dst_buf base
    movs    r4, #0
    ldr     r5, =src_pattern
    ldr     r6, =dst_buf
.Lcmp_loop:
    cmp     r4, #COPY_WORDS
    bge     .Lpass
    lsls    r7, r4, #2                            @ byte offset
    ldr     r0, [r5, r7]
    ldr     r1, [r6, r7]
    cmp     r0, r1
    bne     .Lfail
    adds    r4, #1
    b       .Lcmp_loop

.Lpass:
    bl      _led_on
    ldr     r0, =prefix_ok
    bl      cdc_puts
    ldr     r0, =COPY_WORDS
    bl      _put_uint_decimal
    ldr     r0, =mid_iter
    bl      cdc_puts
    ldr     r0, =iter_count
    ldr     r1, [r0]
    adds    r1, #1
    str     r1, [r0]
    mov     r0, r1
    bl      _put_uint_decimal
    ldr     r0, =suffix_crlf
    bl      cdc_puts
    b       .Lpause

.Lfail:
    @ r4 = failing word index, r0 = expected, r1 = got
    mov     r8, r0                                @ stash expected
    mov     r9, r1                                @ stash got
    bl      _led_off
    ldr     r0, =prefix_fail
    bl      cdc_puts
    mov     r0, r4
    bl      _put_uint_decimal
    ldr     r0, =mid_exp
    bl      cdc_puts
    mov     r0, r8
    bl      _put_hex32
    ldr     r0, =mid_got
    bl      cdc_puts
    mov     r0, r9
    bl      _put_hex32
    ldr     r0, =suffix_crlf
    bl      cdc_puts
    @ Rapid LED flicker on failure - short delay + visible loop here.
.Lfail_blink:
    bl      _led_on
    ldr     r0, =15000000                         @ 100 ms
3:  subs    r0, #1
    bne     3b
    bl      _led_off
    ldr     r0, =15000000
4:  subs    r0, #1
    bne     4b
    b       .Lfail_blink

.Lpause:
    @ ~1 second pause between iterations at 150 MHz
    ldr     r0, =50000000
5:  subs    r0, #1
    bne     5b
    b       .Liter_loop

    .include "src/nvic.S"
