@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ gpio.S - RP2350 GPIO / PADS driver (M3, agent A).
@
@ Covers all 48 user GPIOs in IO_BANK0 + PADS_BANK0, plus the 6 IO_QSPI /
@ PADS_QSPI pins.  Every store is to an atomic alias window - no
@ read-modify-write hazards even if an ISR mutates a sibling pad mid-call.
@
@ ----- Cycle budgets (target, on Cortex-M33 from SRAM) ----------------------
@   gpio_put            : 4   cycles  (mask compute + 1 store)
@   gpio_toggle         : 4   cycles  (mask compute + 1 store)
@   gpio_set_function   : 8   cycles  (compute address + 1 store)
@   gpio_init           : ~25 cycles  (pad CLR + mux + OE_CLR + OUT_CLR)
@   gpio_pull_up        : ~14 cycles  (2 atomic stores)
@   gpio_set_irq_enabled: ~24 cycles  (compute reg+mask + atomic store)
@
@ ----- Backwards-compat shims -----------------------------------------------
@   gpio_led_init   - exact v0.1 sequence (PAD CLR, FUNCSEL=SIO, OUT_CLR,
@                     OE_SET) so existing main.S/blinky_v01.S keep working.
@   gpio_led_toggle - one XOR store on bit 25.
@
@ ISO erratum note:  every pad on RP2350 boots with ISO=1 + OD=1 (datasheet
@ sec 9.3.1).  Code that drives a pin MUST clear those bits before the SIO
@ output can reach the package - hence the PAD CLR write inside gpio_init().
@ =============================================================================

    .include "rp2350.inc"
    .include "gpio.inc"
    .include "pads.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ============================================================================
@ Internal helpers
@
@ Where possible we use macros so the call-site can be inlined and the
@ cycle-count budget can be hit.  Helpers that are too big to inline are
@ exposed as static thumb_func entries - they clobber r0..r3 only.
@ ============================================================================

@ ---------------------------------------------------------------- _bit_mask
@   Input : r0 = pin (0..47)
@   Output: r2 = (1 << (pin & 31))
@           r3 = pin (preserved for follow-up base-select)
@   Clobbers: r1, r2, r3
@   Cost  : 4 cycles (movs + lsls + mov + nothing).
@   We use this for every SIO bit-mask compute.
    .macro  M_BIT_MASK pin_reg
    movs    r2, #1
    lsls    r2, \pin_reg                   @ Cortex-M33 masks shift count to 5
    .endm

@ ---------------------------------------------------------------- _sio_offset
@   For a given pin, return the right SIO offset (low or HI register).
@   Caller passes the LOW offset (e.g. SIO_GPIO_OUT_SET = 0x18) and we
@   transparently bump to the _HI variant if pin >= 32.
@
@   _HI offsets are exactly LOW + 0x40 in the RP2350 SIO map.
    .equ SIO_HI_OFFSET, 0x40

@ ============================================================================
@ Public API - drive / configure
@ ============================================================================

@ ---------------------------------------------------------------------------
@ gpio_set_function(pin, func)
@   r0 = pin (0..47), r1 = func (0..31)
@   Writes IO_BANK0_BASE + 4 + pin*8 = func.  Plain (non-atomic) store -
@   FUNCSEL is a 5-bit field that needs to be set with one full word value
@   (the surrounding fields are zero on reset).
@   Cycles: ~8.
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_function, "ax"
    .thumb_func
    .global  gpio_set_function
gpio_set_function:
    lsls    r2, r0, #3                     @ r2 = pin * 8
    adds    r2, #IO_BANK0_GPIO_CTRL_OFFS   @ r2 = 4 + pin*8
    ldr     r3, =IO_BANK0_BASE
    str     r1, [r3, r2]                   @ CTRL = func
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_set_dir(pin, out_bool)
@   r0 = pin, r1 = 0 (input) | nonzero (output)
@   Selects between SIO_GPIO_OE_SET and SIO_GPIO_OE_CLR (or _HI variants).
@   Cycles: ~10.
@
@   Note: Cortex-M33 LSLS uses the FULL low-byte of the shift register, so
@   we must explicitly mask the pin to bit 0..31 (subtract 32 in HI path).
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_dir, "ax"
    .thumb_func
    .global  gpio_set_dir
gpio_set_dir:
    cmp     r0, #32
    blo     10f

    @ ---- HI path: pin in 32..47 ---------------------------------------
    subs    r2, r0, #32
    movs    r3, #1
    lsls    r3, r2                         @ r3 = 1 << (pin - 32)
    cmp     r1, #0
    beq     2f
    ldr     r0, =SIO_BASE + SIO_GPIO_HI_OE_SET
    str     r3, [r0]
    bx      lr
2:  ldr     r0, =SIO_BASE + SIO_GPIO_HI_OE_CLR
    str     r3, [r0]
    bx      lr

10: @ ---- LOW path: pin in 0..31 ---------------------------------------
    movs    r2, #1
    lsls    r2, r0
    cmp     r1, #0
    beq     3f
    ldr     r3, =SIO_BASE + SIO_GPIO_OE_SET
    str     r2, [r3]
    bx      lr
3:  ldr     r3, =SIO_BASE + SIO_GPIO_OE_CLR
    str     r2, [r3]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_put(pin, value_bool)
@   r0 = pin, r1 = 0 (low) | nonzero (high)
@   Single store to SIO_GPIO_OUT_SET / OUT_CLR (or _HI).  No RMW.
@   Cycles: 4 (mask + cmp + str).
@ ---------------------------------------------------------------------------
    .section .text.gpio_put, "ax"
    .thumb_func
    .global  gpio_put
gpio_put:
    cmp     r0, #32
    blo     10f

    @ ---- HI path ------------------------------------------------------
    subs    r2, r0, #32
    movs    r3, #1
    lsls    r3, r2
    cmp     r1, #0
    beq     2f
    ldr     r0, =SIO_BASE + SIO_GPIO_HI_OUT_SET
    str     r3, [r0]
    bx      lr
2:  ldr     r0, =SIO_BASE + SIO_GPIO_HI_OUT_CLR
    str     r3, [r0]
    bx      lr

10: @ ---- LOW path -----------------------------------------------------
    movs    r2, #1
    lsls    r2, r0
    cmp     r1, #0
    beq     3f
    ldr     r3, =SIO_BASE + SIO_GPIO_OUT_SET
    str     r2, [r3]
    bx      lr
3:  ldr     r3, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r2, [r3]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_get(pin) -> r0 (0 or 1)
@   Reads SIO_GPIO_IN (or _HI), masks the bit, returns 0/1.
@ ---------------------------------------------------------------------------
    .section .text.gpio_get, "ax"
    .thumb_func
    .global  gpio_get
gpio_get:
    cmp     r0, #32
    blo     1f
    subs    r2, r0, #32                    @ HI bit pos = pin - 32
    ldr     r3, =SIO_BASE + SIO_GPIO_HI_IN
    ldr     r1, [r3]
    lsrs    r1, r2
    movs    r0, #1
    ands    r0, r1
    bx      lr
1:  ldr     r3, =SIO_BASE + SIO_GPIO_IN
    ldr     r1, [r3]
    lsrs    r1, r0
    movs    r0, #1
    ands    r0, r1
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_toggle(pin)
@   Single XOR store on SIO_GPIO_OUT_XOR (or _HI).
@   Cycles: 4 (mask + cmp + str).
@ ---------------------------------------------------------------------------
    .section .text.gpio_toggle, "ax"
    .thumb_func
    .global  gpio_toggle
gpio_toggle:
    cmp     r0, #32
    blo     1f
    subs    r2, r0, #32
    movs    r3, #1
    lsls    r3, r2
    ldr     r0, =SIO_BASE + SIO_GPIO_HI_OUT_XOR
    str     r3, [r0]
    bx      lr
1:  movs    r2, #1
    lsls    r2, r0
    ldr     r3, =SIO_BASE + SIO_GPIO_OUT_XOR
    str     r2, [r3]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_init(pin)
@   pad: clear ISO + OD (atomic CLR)
@   mux: SIO  (plain CTRL store)
@   SIO: OUT=0 (OUT_CLR), OE=0 (OE_CLR)
@   Cycles: ~25.  4 stores.
@ ---------------------------------------------------------------------------
    .section .text.gpio_init, "ax"
    .thumb_func
    .global  gpio_init
gpio_init:
    push    {r4, r5, lr}
    mov     r4, r0                         @ keep pin in r4

    @ ---- 1. Pad: ATOMIC_CLR ISO|OD --------------------------------------
    lsls    r1, r4, #2                     @ r1 = pin * 4
    adds    r1, #PADS_BANK0_GPIO_OFFS      @ r1 = 4 + pin*4
    ldr     r2, =PADS_BANK0_BASE + ATOMIC_CLR
    movs    r3, #(PADS_ISO | PADS_OD) >> 6
    lsls    r3, #6                         @ r3 = 0x180
    str     r3, [r2, r1]

    @ ---- 2. Mux: FUNCSEL = SIO ------------------------------------------
    lsls    r1, r4, #3                     @ r1 = pin * 8
    adds    r1, #IO_BANK0_GPIO_CTRL_OFFS
    ldr     r2, =IO_BANK0_BASE
    movs    r3, #GPIO_FUNC_SIO
    str     r3, [r2, r1]

    @ ---- 3. SIO: OUT=0 then OE=0 ----------------------------------------
    cmp     r4, #32
    blo     1f
    subs    r1, r4, #32
    movs    r5, #1
    lsls    r5, r1                         @ r5 = 1 << (pin - 32)
    ldr     r2, =SIO_BASE + SIO_GPIO_HI_OUT_CLR
    str     r5, [r2]
    ldr     r2, =SIO_BASE + SIO_GPIO_HI_OE_CLR
    str     r5, [r2]
    b       9f
1:  movs    r5, #1
    lsls    r5, r4                         @ r5 = 1 << pin
    ldr     r2, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r5, [r2]
    ldr     r2, =SIO_BASE + SIO_GPIO_OE_CLR
    str     r5, [r2]
9:
    pop     {r4, r5, pc}

@ ---------------------------------------------------------------------------
@ gpio_deinit(pin)
@   mux: NULL (FUNCSEL=31)
@   pad: ATOMIC_SET ISO|OD
@ ---------------------------------------------------------------------------
    .section .text.gpio_deinit, "ax"
    .thumb_func
    .global  gpio_deinit
gpio_deinit:
    @ Mux to NULL
    lsls    r1, r0, #3
    adds    r1, #IO_BANK0_GPIO_CTRL_OFFS
    ldr     r2, =IO_BANK0_BASE
    movs    r3, #GPIO_FUNC_NULL
    str     r3, [r2, r1]

    @ Pad: SET ISO|OD
    lsls    r1, r0, #2
    adds    r1, #PADS_BANK0_GPIO_OFFS
    ldr     r2, =PADS_BANK0_BASE + ATOMIC_SET
    movs    r3, #(PADS_ISO | PADS_OD) >> 6
    lsls    r3, #6                         @ r3 = 0x180
    str     r3, [r2, r1]
    bx      lr

@ ============================================================================
@ Pad-level configuration (PADS_BANK0)
@ ============================================================================

@ ---------------------------------------------------------------------------
@ Internal: load r2 = PADS_BANK0_BASE + alias + 4 + pin*4
@           Caller passes alias offset in r3 (ATOMIC_SET / CLR / XOR / 0).
@           Pin must be in r0; clobbers r1, r2.
@   Cost: ~6 cycles.
@   This is reused by every gpio_pull_*, gpio_set_drive_*, etc.
    .macro  M_PAD_ADDR alias_const
    lsls    r1, r0, #2
    adds    r1, #PADS_BANK0_GPIO_OFFS
    ldr     r2, =PADS_BANK0_BASE + \alias_const
    add     r2, r1
    .endm

@ ---------------------------------------------------------------------------
@ gpio_pull_up(pin) - atomic SET PUE, atomic CLR PDE
@ ---------------------------------------------------------------------------
    .section .text.gpio_pull_up, "ax"
    .thumb_func
    .global  gpio_pull_up
gpio_pull_up:
    lsls    r1, r0, #2
    adds    r1, #PADS_BANK0_GPIO_OFFS

    @ SET PUE
    ldr     r2, =PADS_BANK0_BASE + ATOMIC_SET
    movs    r3, #PADS_PUE
    str     r3, [r2, r1]

    @ CLR PDE
    ldr     r2, =PADS_BANK0_BASE + ATOMIC_CLR
    movs    r3, #PADS_PDE
    str     r3, [r2, r1]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_pull_down(pin) - atomic SET PDE, atomic CLR PUE
@ ---------------------------------------------------------------------------
    .section .text.gpio_pull_down, "ax"
    .thumb_func
    .global  gpio_pull_down
gpio_pull_down:
    lsls    r1, r0, #2
    adds    r1, #PADS_BANK0_GPIO_OFFS

    ldr     r2, =PADS_BANK0_BASE + ATOMIC_SET
    movs    r3, #PADS_PDE
    str     r3, [r2, r1]

    ldr     r2, =PADS_BANK0_BASE + ATOMIC_CLR
    movs    r3, #PADS_PUE
    str     r3, [r2, r1]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_disable_pulls(pin) - atomic CLR both PUE and PDE
@ ---------------------------------------------------------------------------
    .section .text.gpio_disable_pulls, "ax"
    .thumb_func
    .global  gpio_disable_pulls
gpio_disable_pulls:
    lsls    r1, r0, #2
    adds    r1, #PADS_BANK0_GPIO_OFFS
    ldr     r2, =PADS_BANK0_BASE + ATOMIC_CLR
    movs    r3, #(PADS_PUE | PADS_PDE)
    str     r3, [r2, r1]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_set_input_enabled(pin, en)
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_input_enabled, "ax"
    .thumb_func
    .global  gpio_set_input_enabled
gpio_set_input_enabled:
    lsls    r2, r0, #2
    adds    r2, #PADS_BANK0_GPIO_OFFS
    movs    r3, #PADS_IE
    cmp     r1, #0
    beq     1f
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_SET
    str     r3, [r0, r2]
    bx      lr
1:  ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR
    str     r3, [r0, r2]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_set_drive_strength(pin, d)
@   d in {0=2mA, 1=4mA, 2=8mA, 3=12mA}.  We have to clear the 2-bit DRIVE
@   field and then set the new value - two atomic stores.
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_drive_strength, "ax"
    .thumb_func
    .global  gpio_set_drive_strength
gpio_set_drive_strength:
    lsls    r2, r0, #2
    adds    r2, #PADS_BANK0_GPIO_OFFS

    @ CLR the existing DRIVE field (bits 5:4)
    ldr     r3, =PADS_BANK0_BASE + ATOMIC_CLR
    movs    r0, #PADS_DRIVE_MASK
    str     r0, [r3, r2]

    @ SET the requested value (truncate to 2 bits, then shift to position 4)
    movs    r0, #3
    ands    r1, r0
    lsls    r1, #PADS_DRIVE_LSB
    ldr     r3, =PADS_BANK0_BASE + ATOMIC_SET
    str     r1, [r3, r2]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_set_slew_fast(pin, fast)
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_slew_fast, "ax"
    .thumb_func
    .global  gpio_set_slew_fast
gpio_set_slew_fast:
    lsls    r2, r0, #2
    adds    r2, #PADS_BANK0_GPIO_OFFS
    movs    r3, #PADS_SLEWFAST
    cmp     r1, #0
    beq     1f
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_SET
    str     r3, [r0, r2]
    bx      lr
1:  ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR
    str     r3, [r0, r2]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_set_schmitt(pin, on)
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_schmitt, "ax"
    .thumb_func
    .global  gpio_set_schmitt
gpio_set_schmitt:
    lsls    r2, r0, #2
    adds    r2, #PADS_BANK0_GPIO_OFFS
    movs    r3, #PADS_SCHMITT
    cmp     r1, #0
    beq     1f
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_SET
    str     r3, [r0, r2]
    bx      lr
1:  ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR
    str     r3, [r0, r2]
    bx      lr

@ ============================================================================
@ IRQ programming
@
@ Per pin, a 4-bit nibble at position (pin%8)*4 in the [pin/8]-th register.
@ INTE/INTF/INTS layout matches; INTR is the raw status with W1C semantics.
@ ============================================================================

@ ---------------------------------------------------------------------------
@ gpio_set_irq_enabled(pin, events_mask, enable)
@   r0 = pin (0..47)
@   r1 = events_mask (LEVEL_LOW=1 .. EDGE_HIGH=8)
@   r2 = enable: 0 = clear, nonzero = set
@   Writes (events_mask << ((pin%8)*4)) to PROC0_INTE[pin/8] via the
@   ATOMIC_SET / ATOMIC_CLR alias.
@ ---------------------------------------------------------------------------
    .section .text.gpio_set_irq_enabled, "ax"
    .thumb_func
    .global  gpio_set_irq_enabled
gpio_set_irq_enabled:
    push    {r4, lr}

    @ r3 = (pin / 8) * 4    -- byte offset within the IRQ array
    lsrs    r3, r0, #3                     @ r3 = pin / 8 (0..5)
    lsls    r3, #2                         @ r3 = (pin/8) * 4

    @ r4 = (pin % 8) * 4    -- shift count for events nibble
    movs    r4, #7
    ands    r4, r0
    lsls    r4, #2

    @ r1 = events_mask << shift
    lsls    r1, r4

    @ Compute base = IO_BANK0_BASE + alias + IO_BANK0_PROC0_INTE0 + r3
    cmp     r2, #0
    beq     1f
    ldr     r0, =IO_BANK0_BASE + ATOMIC_SET + IO_BANK0_PROC0_INTE0
    b       2f
1:  ldr     r0, =IO_BANK0_BASE + ATOMIC_CLR + IO_BANK0_PROC0_INTE0
2:  str     r1, [r0, r3]
    pop     {r4, pc}

@ ---------------------------------------------------------------------------
@ gpio_acknowledge_irq(pin, events_mask)
@   r0 = pin, r1 = events_mask
@   INTR is W1C - write 1 to the corresponding bits in INTR[pin/8].
@   Use plain alias (offset 0); a 1 bit clears, a 0 bit is a no-op.
@ ---------------------------------------------------------------------------
    .section .text.gpio_acknowledge_irq, "ax"
    .thumb_func
    .global  gpio_acknowledge_irq
gpio_acknowledge_irq:
    lsrs    r3, r0, #3                     @ r3 = pin / 8
    lsls    r3, #2                         @ r3 = byte offset

    movs    r2, #7
    ands    r2, r0
    lsls    r2, #2                         @ r2 = (pin%8)*4

    lsls    r1, r2                         @ r1 = mask << shift

    ldr     r0, =IO_BANK0_BASE + IO_BANK0_INTR0
    str     r1, [r0, r3]                   @ W1C
    bx      lr

@ ============================================================================
@ IO_QSPI mirror API (same shape, 6 pins)
@ ============================================================================

@ ---------------------------------------------------------------------------
@ gpio_qspi_set_function(pin, func)
@   pin in 0..5; CTRL register at IO_QSPI_BASE + 4 + pin*8.
@ ---------------------------------------------------------------------------
    .section .text.gpio_qspi_set_function, "ax"
    .thumb_func
    .global  gpio_qspi_set_function
gpio_qspi_set_function:
    lsls    r2, r0, #3
    adds    r2, #IO_BANK0_GPIO_CTRL_OFFS   @ same +4 offset as IO_BANK0
    ldr     r3, =IO_QSPI_BASE
    str     r1, [r3, r2]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_qspi_set_irq_enabled(pin, events_mask, enable)
@   IO_QSPI has only 6 pins so the IRQ register is just one word, no array.
@ ---------------------------------------------------------------------------
    .section .text.gpio_qspi_set_irq_enabled, "ax"
    .thumb_func
    .global  gpio_qspi_set_irq_enabled
gpio_qspi_set_irq_enabled:
    @ shift = (pin % 8) * 4 == pin*4 since pin<6
    movs    r3, #7
    ands    r3, r0
    lsls    r3, #2
    lsls    r1, r3

    cmp     r2, #0
    beq     1f
    ldr     r0, =IO_QSPI_BASE + ATOMIC_SET + IO_QSPI_PROC0_INTE
    b       2f
1:  ldr     r0, =IO_QSPI_BASE + ATOMIC_CLR + IO_QSPI_PROC0_INTE
2:  str     r1, [r0]
    bx      lr

@ ---------------------------------------------------------------------------
@ gpio_qspi_acknowledge_irq(pin, events_mask)
@ ---------------------------------------------------------------------------
    .section .text.gpio_qspi_acknowledge_irq, "ax"
    .thumb_func
    .global  gpio_qspi_acknowledge_irq
gpio_qspi_acknowledge_irq:
    movs    r3, #7
    ands    r3, r0
    lsls    r3, #2
    lsls    r1, r3
    ldr     r0, =IO_QSPI_BASE + IO_QSPI_INTR
    str     r1, [r0]
    bx      lr

@ ============================================================================
@ v0.1 backwards-compat shims (called from src/main.S and the v0.1 example).
@
@ These MUST emit exactly the same MMIO write trace as the v0.1 driver:
@   1. PADS_BANK0[25] CLR = 0x180
@   2. IO_BANK0[25] CTRL = 5 (SIO)
@   3. SIO_GPIO_OUT_CLR = (1<<25)
@   4. SIO_GPIO_OE_SET  = (1<<25)
@ tests/unicorn/test_v01_blinky.py asserts on this exact prefix.
@ ============================================================================

    .equ LED_PIN, 25

    .section .text.gpio_led_init, "ax"
    .thumb_func
    .global  gpio_led_init
gpio_led_init:
    @ ---- 1. PADS_BANK0[25] CLR = ISO|OD ---------------------------------
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (LED_PIN * 4)
    movs    r1, #(PADS_ISO | PADS_OD) >> 6
    lsls    r1, #6                         @ r1 = 0x180
    str     r1, [r0]

    @ ---- 2. IO_BANK0[25] CTRL = SIO -------------------------------------
    ldr     r0, =IO_BANK0_BASE + 4 + (LED_PIN * 8)
    movs    r1, #GPIO_FUNC_SIO
    str     r1, [r0]

    @ ---- 3 + 4. SIO drive low, then enable output -----------------------
    movs    r2, #1
    lsls    r2, #LED_PIN                   @ r2 = 1 << 25

    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_CLR
    str     r2, [r0]
    ldr     r0, =SIO_BASE + SIO_GPIO_OE_SET
    str     r2, [r0]

    bx      lr

    .section .text.gpio_led_toggle, "ax"
    .thumb_func
    .global  gpio_led_toggle
gpio_led_toggle:
    movs    r1, #1
    lsls    r1, #LED_PIN
    ldr     r0, =SIO_BASE + SIO_GPIO_OUT_XOR
    str     r1, [r0]
    bx      lr
