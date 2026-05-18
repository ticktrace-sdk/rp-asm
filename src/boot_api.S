@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ boot_api.S - App-side library for talking to the ticktrace bootloader.
@
@ Functions an app links to interact with the TSBL it was booted by. Free
@ to link or omit per-app: a "fire and forget" app doesn't need any of
@ this; an A/B-aware app calls boot_confirm() early in main(); a DFU-
@ capable app calls boot_request_dfu() on user command.
@
@ All functions are AAPCS leaves (no stack frame, preserve r4+).
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"
    .include "bootloader.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ BOOT_AB_SCRATCH,    WATCHDOG_BASE + WATCHDOG_SCRATCH0 + (BL_SCRATCH_AB_REG * 4)
    .equ BOOT_FLAG_SCRATCH,  WATCHDOG_BASE + WATCHDOG_SCRATCH0 + (BL_SCRATCH_REG * 4)

@ ----------------------------------------------------------------------------
@ void boot_confirm(void);
@
@ Clears WATCHDOG_SCRATCH[6]. Call this once the app has decided it is
@ healthy and shouldn't be rolled back on the next warm reset. Typically
@ the first thing main() does, but more security-conscious apps may
@ defer until after they've sanity-checked their own peripherals.
@ ----------------------------------------------------------------------------
    .section .text.boot_confirm, "ax"
    .thumb_func
    .align   2
    .global  boot_confirm
boot_confirm:
    ldr     r0, =BOOT_AB_SCRATCH
    movs    r1, #0
    str     r1, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ void boot_request_dfu(void) __attribute__((noreturn));
@
@ Sets WATCHDOG_SCRATCH[7] = BL_SCRATCH_FORCE_DFU and triggers an immediate
@ watchdog reset. The TSBL (any DFU-capable flavor) sees the marker on
@ its way up and enters DFU mode. Does not return.
@ ----------------------------------------------------------------------------
    .section .text.boot_request_dfu, "ax"
    .thumb_func
    .align   2
    .global  boot_request_dfu
boot_request_dfu:
    ldr     r0, =BOOT_FLAG_SCRATCH
    ldr     r1, =BL_SCRATCH_FORCE_DFU
    str     r1, [r0]
    b       _boot_watchdog_reset

@ ----------------------------------------------------------------------------
@ void boot_request_bootsel(void) __attribute__((noreturn));
@
@ Variant: punt all the way back to the mask-ROM BOOTSEL drive. Useful for
@ "factory reset" buttons. Does not return.
@ ----------------------------------------------------------------------------
    .section .text.boot_request_bootsel, "ax"
    .thumb_func
    .align   2
    .global  boot_request_bootsel
boot_request_bootsel:
    ldr     r0, =BOOT_FLAG_SCRATCH
    ldr     r1, =BL_SCRATCH_FORCE_BOOTSEL
    str     r1, [r0]
    @ Fallthrough.

@ ----------------------------------------------------------------------------
@ _boot_watchdog_reset - internal helper, triggers immediate watchdog reset.
@ ----------------------------------------------------------------------------
    .section .text._boot_watchdog_reset, "ax"
    .thumb_func
    .align   2
    .global  _boot_watchdog_reset
_boot_watchdog_reset:
    ldr     r0, =WATCHDOG_BASE
    ldr     r1, =WATCHDOG_CTRL_TRIGGER
    str     r1, [r0, #WATCHDOG_CTRL]
1:  wfi
    b       1b
