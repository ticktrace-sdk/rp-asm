@ =============================================================================
@ bootrom.S - look up + call RP2350 bootrom service functions.
@
@ The RP2350 bootrom exposes a table of functions identified by 16-bit
@ ASCII codes (e.g. 'U','B' for reset_usb_boot, 'R','B' for reboot).
@ A 16-bit pointer to the rom_table_lookup function sits at the fixed
@ ROM address 0x7df8; the function takes (code, flag) and returns the
@ resolved service function pointer (or 0 if not found).
@
@ For Cortex-M33 ARM Secure (our default mode) we pass
@ RT_FLAG_FUNC_ARM_SEC = 0x0004.  Non-secure code would use 0x0010.
@
@ Public API:
@   rom_func_lookup(code) -> r0         resolve ROM service to address
@   rom_reset_to_bootsel                jump into BOOTSEL mode (no return)
@
@ Reference: RP2350 datasheet sec 5.5.7, pico-sdk src/rp2_common/pico_bootrom.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ BOOTROM_TABLE_LOOKUP_OFFSET, 0x7df8
    .equ RT_FLAG_FUNC_ARM_SEC,        0x0004

    @ ROM_TABLE_CODE packs the two ASCII characters as c1 | (c2 << 8).
    .equ ROM_FUNC_RESET_USB_BOOT,     ('U' | ('B' << 8))   @ 0x4255

@ ----------------------------------------------------------------------------
@ rom_func_lookup(code) -> r0 = function address (or 0 if not found)
@   r0 = 16-bit ROM_TABLE_CODE
@ Clobbers: r0-r3, r12.
@ ----------------------------------------------------------------------------
    .section .text.rom_func_lookup, "ax"
    .thumb_func
    .global  rom_func_lookup
rom_func_lookup:
    push    {lr}
    movs    r1, #RT_FLAG_FUNC_ARM_SEC         @ arg2: flag selector
    ldr     r2, =BOOTROM_TABLE_LOOKUP_OFFSET
    ldrh    r2, [r2]                          @ r2 = thumb-encoded lookup fn
    blx     r2                                @ r0 = looked-up address
    pop     {pc}

@ ----------------------------------------------------------------------------
@ rom_reset_to_bootsel - reboot into BOOTSEL mode and never return.
@   Useful for triggering an unbrick / re-flash from firmware so the user
@   doesn't have to power-cycle and hold BOOTSEL.
@ Clobbers: everything (no return).
@ ----------------------------------------------------------------------------
    .section .text.rom_reset_to_bootsel, "ax"
    .thumb_func
    .global  rom_reset_to_bootsel
rom_reset_to_bootsel:
    push    {lr}
    movw    r0, #ROM_FUNC_RESET_USB_BOOT
    bl      rom_func_lookup
    cbz     r0, .Lbootsel_fail                @ couldn't resolve - hang
    mov     r3, r0                            @ r3 = reset_usb_boot fn
    movs    r0, #0                            @ arg1: no GPIO activity pin
    movs    r1, #0                            @ arg2: don't disable any iface
    blx     r3                                @ should not return
.Lbootsel_fail:
    b       .Lbootsel_fail
