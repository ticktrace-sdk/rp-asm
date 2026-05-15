@ =============================================================================
@ blinky_confirmed_demo.S - slot A app for the TSBL-ab rollback demo.
@
@ Same bring-up as src/main.S blinky, but calls boot_confirm() early - this
@ clears WATCHDOG_SCRATCH[6], telling the TSBL "I'm healthy, don't rollback
@ to the other slot on next reset".
@
@ Blinks at ~2 Hz (visually slow). The buggy slot-B variant blinks at
@ ~10 Hz, so on real silicon you can tell which app is running:
@
@   Power-on with both slots flashed:
@     1. TSBL picks slot B (higher seq), sets scratch=TRY_B.
@     2. Slot B (buggy) blinks fast for ~3 s, arms own watchdog, never confirms.
@     3. Watchdog fires; warm reset preserves scratch=TRY_B.
@     4. TSBL sees TRY_B, rolls back to slot A.
@     5. Slot A (this app) calls boot_confirm, blinks slow forever.
@
@ Banner over UART0 distinguishes the two as well:
@     "rp-asm slot A (confirmed, ~2 Hz)"
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ DELAY_2HZ, 12500000

    .section .rodata.banner_confirmed, "a"
banner_confirmed:
    .asciz "rp-asm slot A (confirmed, ~2 Hz)\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ Standard clock-tree bring-up (matches src/main.S).
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    @ Clear WATCHDOG_SCRATCH[6]: tell the TSBL we made it. From here on,
    @ a warm reset (e.g. user pulls USB) will boot this same slot again
    @ instead of rolling back.
    bl      boot_confirm

    ldr     r0, =banner_confirmed
    bl      uart0_puts

.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =DELAY_2HZ
1:  subs    r0, #1
    bne     1b
    b       .Lloop
