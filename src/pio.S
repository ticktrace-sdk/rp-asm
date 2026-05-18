@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ pio.S - RP2350 PIO controller driver (M5-I)
@
@ Provides the host-side ("C runtime") functions to program a PIO block and
@ talk to its state machines.  PIO program assembly itself is done off-line
@ (see examples/pio_blink_program.S for the hand-encoded blink program; a
@ proper `pioasm` Python tool is deferred; see ROADMAP.md).
@
@ Public API:
@   pio_init(r0=pio_idx)                                 deassert RESETS
@   pio_add_program(r0=pio_idx, r1=prog, r2=len_words, r3=origin) -> r0(offset)
@   pio_sm_set_clkdiv(r0=pio_idx, r1=sm, r2=int, r3=frac)
@   pio_sm_set_wrap(r0=pio_idx, r1=sm, r2=bottom, r3=top)
@   pio_sm_set_out_pins(r0=pio_idx, r1=sm, r2=base, r3=count)
@   pio_sm_set_set_pins(r0=pio_idx, r1=sm, r2=base, r3=count)
@   pio_sm_set_enabled(r0=pio_idx, r1=sm, r2=on)
@   pio_sm_put(r0=pio_idx, r1=sm, r2=value)              blocks on TX full
@   pio_sm_get(r0=pio_idx, r1=sm) -> r0                  blocks on RX empty
@   pio_sm_exec(r0=pio_idx, r1=sm, r2=instr)             write SM_INSTR
@   pio_gpio_init(r0=pio_idx, r1=pin)                    gpio_set_function(pin, 6+pio_idx)
@ =============================================================================

    .include "pio.inc"
    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ -----------------------------------------------------------------------------
@ pio_base(idx) - returns base in r0. Clobbers r12. Macro inlined.
@ -----------------------------------------------------------------------------
    .macro M_PIO_BASE rd, ridx, scratch
    cmp     \ridx, #0
    bne     1f
    ldr     \rd, =PIO0_BASE
    b       9f
1:  cmp     \ridx, #1
    bne     2f
    ldr     \rd, =PIO1_BASE
    b       9f
2:  ldr     \rd, =PIO2_BASE
9:
    .endm

    .section .text.pio_init, "ax"
    .thumb_func
    .global  pio_init
pio_init:
    @ r0=idx. Compute RESETS bit = 11 + idx (pio0=11, pio1=12, pio2=13)
    movs    r1, #1
    adds    r2, r0, #RESETS_pio0
    lsls    r1, r2
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b
    bx      lr

@ -----------------------------------------------------------------------------
@ pio_add_program(idx, prog, len_words, origin)
@   Copy `len_words` 32-bit-stored instructions (the .inc-file output stores
@   each 16-bit instruction in a 32-bit word for ease) into INSTR_MEM starting
@   at `origin` (or 0 if origin == -1).  Returns the load offset in r0.
@   Note: program words are stored only in the low 16 bits; the SM only reads
@   16 bits but the instruction-memory register is 32-bit wide and ignores
@   the upper half.
@ -----------------------------------------------------------------------------
    .section .text.pio_add_program, "ax"
    .thumb_func
    .global  pio_add_program
pio_add_program:
    push    {r4, r5, r6, r7, lr}
    @ r0=idx, r1=prog, r2=len, r3=origin
    M_PIO_BASE r4, r0, r6                 @ r4 = pio base
    mov     r5, r1                        @ r5 = source ptr
    mov     r6, r2                        @ r6 = count
    cmp     r3, #-1
    bne     1f
    movs    r3, #0                        @ default origin = 0
1:  mov     r7, r3                        @ r7 = load offset
    @ Destination: PIO_INSTR_MEM0 + offset*4
    adds    r0, r4, #PIO_INSTR_MEM0
    lsls    r2, r7, #2
    adds    r0, r2
2:  cmp     r6, #0
    beq     3f
    ldr     r1, [r5], #4
    str     r1, [r0], #4
    subs    r6, #1
    b       2b
3:  mov     r0, r7                        @ return offset
    pop     {r4, r5, r6, r7, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_set_clkdiv(idx, sm, int_div, frac_div)
@   CLKDIV = (int<<16) | (frac<<8)
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_set_clkdiv, "ax"
    .thumb_func
    .global  pio_sm_set_clkdiv
pio_sm_set_clkdiv:
    push    {r4, lr}
    M_PIO_BASE r4, r0, r12
    movs    r0, #PIO_SM_STRIDE
    muls    r0, r0, r1
    adds    r0, r0, #PIO_SM0_CLKDIV
    @ value = (int<<16) | (frac<<8)
    lsls    r2, r2, #16
    and     r3, #0xFF
    lsls    r3, #8
    orrs    r2, r3
    str     r2, [r4, r0]
    pop     {r4, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_set_wrap(idx, sm, bottom, top)
@   Read-modify-write SM_EXECCTRL with the WRAP fields.  Other fields keep
@   their current value, which is fine because we expect this to be called
@   before the SM is enabled (so they're at reset = 0).
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_set_wrap, "ax"
    .thumb_func
    .global  pio_sm_set_wrap
pio_sm_set_wrap:
    push    {r4, r5, lr}
    M_PIO_BASE r4, r0, r12
    movs    r0, #PIO_SM_STRIDE
    muls    r0, r0, r1
    adds    r0, r0, #PIO_SM0_EXECCTRL
    ldr     r5, [r4, r0]
    @ Clear bits [16:7] (WRAP_BOTTOM[11:7] + WRAP_TOP[16:12]).
    @ Mask = 0x0001_FF80; WRAP_TOP resets to 0x1F so getting bits 13/14/15
    @ wrong here lets stale ones stay and the SM runs past the program.
    movw    r1, #0xFF80                   @ low half: bits 7..15
    movt    r1, #0x0001                   @ high half: bit 16
    bic     r5, r5, r1
    @ Pack: bottom @ bit 7, top @ bit 12
    and     r2, #0x1F
    lsls    r2, #PIO_EXECCTRL_WRAP_BOTTOM_SHIFT
    and     r3, #0x1F
    lsls    r3, #PIO_EXECCTRL_WRAP_TOP_SHIFT
    orrs    r5, r2
    orrs    r5, r3
    str     r5, [r4, r0]
    pop     {r4, r5, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_set_out_pins(idx, sm, base, count)
@   Update OUT_BASE / OUT_COUNT in PINCTRL.
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_set_out_pins, "ax"
    .thumb_func
    .global  pio_sm_set_out_pins
pio_sm_set_out_pins:
    push    {r4, r5, lr}
    M_PIO_BASE r4, r0, r12
    movs    r0, #PIO_SM_STRIDE
    muls    r0, r0, r1
    adds    r0, r0, #PIO_SM0_PINCTRL
    ldr     r5, [r4, r0]
    @ Clear OUT_BASE[4:0] and OUT_COUNT[25:20]
    movw    r1, #0x001F
    movt    r1, #0x03F0
    bic     r5, r5, r1
    and     r2, #0x1F
    orrs    r5, r2
    and     r3, #0x3F
    lsls    r3, #PIO_PINCTRL_OUT_COUNT_SHIFT
    orrs    r5, r3
    str     r5, [r4, r0]
    pop     {r4, r5, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_set_set_pins(idx, sm, base, count)
@   Update SET_BASE / SET_COUNT in PINCTRL.
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_set_set_pins, "ax"
    .thumb_func
    .global  pio_sm_set_set_pins
pio_sm_set_set_pins:
    push    {r4, r5, lr}
    M_PIO_BASE r4, r0, r12
    movs    r0, #PIO_SM_STRIDE
    muls    r0, r0, r1
    adds    r0, r0, #PIO_SM0_PINCTRL
    ldr     r5, [r4, r0]
    @ Clear SET_BASE[9:5] and SET_COUNT[28:26]
    movw    r1, #0x03E0
    movt    r1, #0x1C00
    bic     r5, r5, r1
    and     r2, #0x1F
    lsls    r2, #PIO_PINCTRL_SET_BASE_SHIFT
    orrs    r5, r2
    and     r3, #0x7
    lsls    r3, #PIO_PINCTRL_SET_COUNT_SHIFT
    orrs    r5, r3
    str     r5, [r4, r0]
    pop     {r4, r5, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_set_enabled(idx, sm, on)
@   CTRL.SM_ENABLE bit sm = on
@   Uses the atomic SET/CLR aliases so other SMs aren't disturbed.
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_set_enabled, "ax"
    .thumb_func
    .global  pio_sm_set_enabled
pio_sm_set_enabled:
    push    {r4, lr}
    M_PIO_BASE r4, r0, r12
    movs    r0, #1
    lsls    r0, r1                         @ r0 = 1 << sm
    cmp     r2, #0
    beq     1f
    @ SET alias
    add     r3, r4, #0x2000
    adds    r3, #PIO_CTRL
    str     r0, [r3]
    pop     {r4, pc}
1:  @ CLR alias
    add     r3, r4, #0x3000
    adds    r3, #PIO_CTRL
    str     r0, [r3]
    pop     {r4, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_put(idx, sm, value)
@   Spin on TX_FULL bit for `sm`; then store `value` to TXFn.
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_put, "ax"
    .thumb_func
    .global  pio_sm_put
pio_sm_put:
    push    {r4, r5, lr}
    M_PIO_BASE r4, r0, r12
    movs    r5, #1
    lsls    r5, r1                         @ r5 = 1 << sm  (TX_FULL mask is bits[3:0])
1:  ldr     r0, [r4, #PIO_FSTAT]
    tst     r0, r5
    bne     1b
    @ TXFn address = PIO_TXF0 + sm*4
    movs    r0, #PIO_TXF0
    lsls    r3, r1, #2
    adds    r0, r3
    str     r2, [r4, r0]
    pop     {r4, r5, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_get(idx, sm) -> r0
@   Spin on RX_EMPTY bit for `sm`; then load from RXFn.
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_get, "ax"
    .thumb_func
    .global  pio_sm_get
pio_sm_get:
    push    {r4, r5, lr}
    M_PIO_BASE r4, r0, r12
    movs    r5, #1
    lsls    r5, r1                         @ r5 = 1 << sm (raw position)
    lsls    r5, #PIO_FSTAT_RX_EMPTY_SHIFT
1:  ldr     r0, [r4, #PIO_FSTAT]
    tst     r0, r5
    bne     1b
    movs    r0, #PIO_RXF0
    lsls    r3, r1, #2
    adds    r0, r3
    ldr     r0, [r4, r0]
    pop     {r4, r5, pc}

@ -----------------------------------------------------------------------------
@ pio_sm_exec(idx, sm, instr)
@   Write `instr` to SM_INSTR; executed immediately by the SM.
@ -----------------------------------------------------------------------------
    .section .text.pio_sm_exec, "ax"
    .thumb_func
    .global  pio_sm_exec
pio_sm_exec:
    push    {r4, lr}
    M_PIO_BASE r4, r0, r12
    movs    r0, #PIO_SM_STRIDE
    muls    r0, r0, r1
    adds    r0, r0, #PIO_SM0_INSTR
    str     r2, [r4, r0]
    pop     {r4, pc}

@ -----------------------------------------------------------------------------
@ pio_gpio_init(idx, pin)
@   Set GPIO function = PIO0|PIO1|PIO2 on pin via gpio_set_function.
@ -----------------------------------------------------------------------------
    .section .text.pio_gpio_init, "ax"
    .thumb_func
    .global  pio_gpio_init
pio_gpio_init:
    push    {lr}
    adds    r0, r0, #GPIO_FUNC_PIO0       @ r0 = 6+idx (func code)
    mov     r2, r0                        @ r2 = func
    mov     r0, r1                        @ r0 = pin
    mov     r1, r2                        @ r1 = func
    bl      gpio_set_function
    pop     {pc}
