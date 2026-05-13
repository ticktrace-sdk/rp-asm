@ =============================================================================
@ examples/bootsel_usb_demo.S - exercise rom_reset_to_bootsel + BOOTRAM.
@
@ The point of this demo is to make re-flashing the Pico 2 hands-free:
@ no more "unplug, hold BOOTSEL, replug".  Two paths are exercised:
@
@   1. Implicit (1200-baud trick).  When the host issues a CDC
@      SET_LINE_CODING with dwDTERate == 1200 the USB stack itself
@      (see src/usb.S) calls rom_reset_to_bootsel and the device
@      re-enumerates as RPI-RP2.  This matches the convention used by
@      tinygo, picotool, and the Arduino-mbed core - you only have to
@      type `stty -F /dev/ttyACM0 1200` on the host.
@
@   2. Explicit ('b' on the wire).  Typing the byte 'b' (or 'B') in a
@      minicom/screen session also triggers the reboot.  Useful when
@      stty isn't easy to reach (e.g. from a serial-monitor UI).
@
@ At boot we also write a small "I was here" cookie into BOOTRAM and
@ print it back, demonstrating that the 1 KiB at 0x400E0000 is
@ application-usable scratch.  The bootrom clobbers BOOTRAM during
@ early boot, so the cookie won't survive a reset - the value printed
@ should be exactly what we just stored a few cycles earlier.
@
@ Verify (Linux):
@   minicom -D /dev/ttyACM0 -b 115200    # see banner + BOOTRAM cookie
@   <type 'b'>                            # device reboots into BOOTSEL
@      -> RPI-RP2 mass-storage drive appears, ready for a new UF2
@   - or -
@   stty -F /dev/ttyACM0 1200             # same reboot, via 1200-baud trick
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .include "rp2350.inc"
    .include "usb.inc"
    .include "bootram.inc"

    .section .rodata.bootsel_demo, "a"
banner_uart:    .asciz "rp-asm M7 - bootsel demo v3 (DTR-edge banner, cookie@0x100)\r\n"
banner_cdc:     .asciz "rp-asm bootsel demo [v3]. 'b' to BOOTSEL, or open at 1200 baud.\r\n"
prefix_cookie:  .asciz "bootram_cookie=0x"
suffix_crlf:    .asciz "\r\n"

    .equ BOOTRAM_COOKIE_VALUE,  0xCAFE2350

@ ----------------------------------------------------------------------------
@ _put_hex8(value) - send 8 hex digits over CDC.  Clobbers r0-r3.
@ ----------------------------------------------------------------------------
    .section .text._put_hex8, "ax"
    .thumb_func
_put_hex8:
    push    {r4, lr}
    mov     r3, r0
    movs    r4, #8
1:  subs    r4, #1
    lsls    r2, r4, #2                              @ shift = 4 * digit
    mov     r1, r3
    lsr     r1, r1, r2
    and     r1, r1, #0xF
    cmp     r1, #10
    blt     2f
    adds    r1, #('a' - 10)
    b       3f
2:  adds    r1, #'0'
3:  mov     r0, r1
    bl      cdc_putc
    cmp     r4, #0
    bne     1b
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

    @ Write our cookie into BOOTRAM at the first application-free slot
    @ (offset 0x100; offsets 0..0xFF hold the bootrom's boot2 stub and
    @ must not be touched - the SDK uses that copy to re-enable XIP
    @ after flash ops, and writing 0xCAFE2350 there yields a stale read
    @ because the bootrom rewrites it shortly after).
    ldr     r0, =BOOTRAM_APP_BASE
    ldr     r1, =BOOTRAM_COOKIE_VALUE
    str     r1, [r0]

    bl      usb_device_init
    movs    r0, #USBCTRL_IRQ
    ldr     r1, =usb_device_isr
    bl      nvic_install_handler
    movs    r0, #USBCTRL_IRQ
    bl      nvic_enable_irq

    @ The host enumerates the device a beat *before* userspace opens
    @ /dev/ttyACM0.  Until the open happens, the host doesn't pull bulk
    @ IN data, so anything we cdc_puts now sits in EP1 IN forever and
    @ the next cdc_puts call blocks (= "solid LED, no banner").
    @
    @ The USB CDC SET_CONTROL_LINE_STATE request fires when userspace
    @ opens the port with DTR asserted, so we wait for cdc_dtr to go
    @ high before printing.  We re-arm on every rising edge so reopening
    @ the port (e.g. after `stty 1200` reboot+flash cycle) reprints.
    movs    r5, #0                                  @ r5 = last seen DTR

.Lbanner_loop:
    @ Toggle the LED every spin so a totally-stuck firmware shows a
    @ steady LED while a working one shows a slow blink.
    bl      gpio_led_toggle

    ldr     r0, =cdc_dtr
    ldr     r4, [r0]                                @ r4 = current DTR
    cmp     r4, r5
    beq     .Lbanner_park                           @ no edge - just park
    movs    r5, r4
    cbz     r4, .Lbanner_park                       @ falling edge - nothing to do

    @ Rising edge: host just opened the port, print banner once.
    ldr     r0, =banner_cdc
    bl      cdc_puts
    ldr     r0, =prefix_cookie
    bl      cdc_puts
    ldr     r0, =BOOTRAM_APP_BASE
    ldr     r0, [r0]
    bl      _put_hex8
    ldr     r0, =suffix_crlf
    bl      cdc_puts

    @ After the first banner is out, fall straight into the interactive
    @ loop.  cdc_available there is the polling hook.
    b       .Lloop

.Lbanner_park:
    @ Park ~250 ms then re-check.  Don't wfi forever - if the host never
    @ opens the port we still want the LED to blink as proof of life.
    ldr     r2, =375000
1:  subs    r2, #1
    bne     1b
    b       .Lbanner_loop

    @ Interactive mode.  Heartbeat the LED at ~2 Hz so the user can see
    @ the firmware is still alive after the banner; toggle each time we
    @ either get a byte or fall through a ~250 ms park window.
.Lloop:
    bl      cdc_available
    cbz     r0, .Lpark
1:  bl      cdc_getc
    cmp     r0, #0
    blt     .Lpark
    @ 'b' or 'B' -> reboot to BOOTSEL.  Otherwise echo the byte back so
    @ minicom feels alive.
    cmp     r0, #'b'
    beq     .Lreboot
    cmp     r0, #'B'
    beq     .Lreboot
    bl      cdc_putc
    bl      cdc_available
    cbz     r0, .Lpark
    b       1b

.Lreboot:
    bl      rom_reset_to_bootsel
    b       .                                       @ unreachable

.Lpark:
    bl      gpio_led_toggle
    ldr     r2, =375000
2:  subs    r2, #1
    bne     2b
    b       .Lloop

    .include "src/nvic.S"
