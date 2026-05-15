@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ i2c.S - RP2350 DesignWare DW_apb_i2c driver (M4-F).
@
@ Public API (AAPCS - r0..r3 are arg registers; r4..r11 callee-saved):
@
@   i2c_init(idx, baudrate_hz)              — RESETS clear + IC_ENABLE=0 +
@                                              IC_CON + HCNT/LCNT/SDA_HOLD +
@                                              IC_FS_SPKLEN + IC_ENABLE=1
@   i2c_deinit(idx)                         — IC_ENABLE=0, RESETS assert
@   i2c_set_baudrate(idx, hz)               — recompute SCL counts
@   i2c_set_slave_mode(idx, addr)           — IC_ENABLE=0, IC_SAR=addr,
@                                              IC_CON in slave mode, IC_ENABLE=1
@   i2c_write_blocking(idx, addr, src, len, nostop_bool) -> r0
@   i2c_read_blocking (idx, addr, dst, len, nostop_bool) -> r0
@   i2c_set_pins(idx, sda_pin, scl_pin)     — gpio_set_function + pull-up on
@                                              both pins
@   i2c_set_irqs_enabled(idx, mask)         — IC_INTR_MASK = mask
@   i2c_clear_irq(idx, which)               — read the appropriate IC_CLR_*
@   i2c_set_dma_enabled(idx, tx, rx)        — IC_DMA_CR
@   i2c_get_status(idx) -> r0               — read IC_STATUS
@
@ Cycle budgets (Cortex-M33 from SRAM, no APB wait states):
@
@   _i2c_base:                3 cycles (table-walk via cmp + ldr)
@   i2c_init:                 ~30 cycles + DesignWare's own settling
@   i2c_set_baudrate:         ~40 cycles (UDIV pair + multiple stores)
@   i2c_set_pins:             ~40 cycles (2 x gpio_set_function + 2 x pull_up)
@   i2c_write_blocking small: dominated by bus speed, not CPU
@   i2c_clear_irq:            6 cycles (1 read; the side-effect IS the read)
@
@ Calling-convention notes:
@   Most public entry points push {r4-r7, lr} so the per-instance base can
@   live in r4 across the body, the address argument in r5, the buffer in
@   r6, and a length counter in r7.  This matches the pattern used in
@   src/dma.S / src/pwm.S - keeps the inner loops tight without spilling.
@
@ Datasheet ref: RP2350 datasheet rev 0.3 (Aug 2024) section 12.4 plus the
@ Synopsys DW_apb_i2c databook for the per-register semantics.
@ =============================================================================

    .include "rp2350.inc"
    .include "i2c.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ _i2c_base(idx) -> r0 = base
@   Internal helper: idx in {0, 1} -> I2C0_BASE / I2C1_BASE.
@   Implemented as a simple branch so we don't need a 0x8000 multiply.
@   Cycles: 3 (cmp + ldr).
@ ----------------------------------------------------------------------------
    .section .text._i2c_base, "ax"
    .thumb_func
_i2c_base:
    cbz     r0, 1f
    ldr     r0, =I2C1_BASE
    bx      lr
1:  ldr     r0, =I2C0_BASE
    bx      lr

@ ----------------------------------------------------------------------------
@ _i2c_disable(base) - clear IC_ENABLE so config registers become writable.
@   r0 = base; clobbers r1.
@ ----------------------------------------------------------------------------
    .section .text._i2c_disable, "ax"
    .thumb_func
_i2c_disable:
    movs    r1, #0
    str     r1, [r0, #IC_ENABLE]
    bx      lr

@ ----------------------------------------------------------------------------
@ i2c_init(idx, baudrate_hz)
@   r0 = idx (0 or 1)
@   r1 = baudrate_hz (e.g. 100000 / 400000 / 1000000)
@
@ Sequence per DesignWare databook §3.2.1:
@   1. Pull RESETS bit out of reset; spin on RESET_DONE.
@   2. IC_ENABLE = 0 (config registers become writable).
@   3. IC_CON = master FS (RESTART_EN, SLAVE_DISABLE, TX_EMPTY_CTRL).
@   4. IC_FS_SPKLEN = glitch filter cycles.
@   5. SCL HCNT/LCNT + IC_SDA_HOLD via i2c_set_baudrate(idx, baudrate_hz).
@   6. IC_TX_TL = 0, IC_RX_TL = 0 (interrupt thresholds; tests verify this).
@   7. IC_DMA_CR = 0 (DMA off until i2c_set_dma_enabled).
@   8. IC_ENABLE = 1.
@
@ Clobbers: r0-r3, r4-r6 (preserved via push/pop).
@ ----------------------------------------------------------------------------
    .section .text.i2c_init, "ax"
    .thumb_func
    .global  i2c_init
i2c_init:
    push    {r4, r5, r6, lr}
    mov     r4, r0                          @ r4 = idx
    mov     r5, r1                          @ r5 = baudrate

    @ ---- 1. Release the I2C block from reset ---------------------------
    @ bit position = 4 + idx (RESETS_i2c0=4, RESETS_i2c1=5).
    movs    r2, #1
    adds    r3, r4, #RESETS_i2c0
    lsls    r2, r3                          @ r2 = 1 << (4+idx)
    ldr     r3, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r2, [r3]
    ldr     r3, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r6, [r3]
    ands    r6, r2
    beq     1b

    @ ---- 2. Compute base into r6 (callee-saved). -----------------------
    mov     r0, r4
    bl      _i2c_base
    mov     r6, r0

    @ ---- 3. Disable so we can write config registers. ------------------
    mov     r0, r6
    bl      _i2c_disable

    @ ---- 4. IC_CON = master FS ----------------------------------------
    ldr     r2, =I2C_CON_MASTER_FS
    str     r2, [r6, #IC_CON]

    @ ---- 5. IC_FS_SPKLEN ----------------------------------------------
    movs    r2, #I2C_FS_SPKLEN_DEFAULT
    str     r2, [r6, #IC_FS_SPKLEN]

    @ ---- 6. SCL counts + sda hold via i2c_set_baudrate -----------------
    @ i2c_set_baudrate expects the peripheral disabled, which we did above.
    mov     r0, r4
    mov     r1, r5
    bl      i2c_set_baudrate

    @ ---- 7. Zero TX/RX thresholds + DMA off ----------------------------
    movs    r2, #0
    str     r2, [r6, #IC_TX_TL]
    str     r2, [r6, #IC_RX_TL]
    str     r2, [r6, #IC_DMA_CR]
    str     r2, [r6, #IC_INTR_MASK]         @ all IRQs masked

    @ ---- 8. IC_ENABLE = 1 ----------------------------------------------
    movs    r2, #IC_ENABLE_ENABLE
    str     r2, [r6, #IC_ENABLE]

    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ i2c_deinit(idx)
@   r0 = idx
@   IC_ENABLE = 0; assert RESETS bit (peripheral fully halted).
@ ----------------------------------------------------------------------------
    .section .text.i2c_deinit, "ax"
    .thumb_func
    .global  i2c_deinit
i2c_deinit:
    push    {r4, lr}
    mov     r4, r0                          @ r4 = idx
    bl      _i2c_base
    bl      _i2c_disable

    @ Assert RESETS bit (set bit 4+idx via SET alias).
    movs    r1, #1
    adds    r2, r4, #RESETS_i2c0
    lsls    r1, r2                          @ r1 = 1 << (4+idx)
    ldr     r2, =RESETS_BASE + ATOMIC_SET + RESETS_RESET
    str     r1, [r2]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ i2c_set_baudrate(idx, hz)
@   r0 = idx, r1 = hz
@
@ For the DW_apb_i2c, SCL HCNT/LCNT are programmed in IC clock cycles.
@ With clk_peri = 150 MHz, period = ~6.67 ns.  Per the I2C-bus spec §6.1
@ the high/low counts must each be at least the "bus high time / bus low
@ time" for the chosen speed:
@
@   Standard 100 kHz: tHIGH >= 4000 ns, tLOW >= 4700 ns
@   Fast     400 kHz: tHIGH >=  600 ns, tLOW >= 1300 ns
@   Fast+    1 MHz  : tHIGH >=  260 ns, tLOW >=  500 ns
@
@ Plus the DesignWare adds a fixed offset (HCNT-1 cycles of high after the
@ programmed count - see databook §6.17.1).  We use the simple formula:
@   period_ticks = clk_peri / freq
@   HCNT = period_ticks * 0.4 - 8 (clipped to >= 8)
@   LCNT = period_ticks * 0.6 - 1 (clipped to >= 8)
@ which gives the table values for the three standard frequencies (within
@ +/- 1 LSB rounding).
@
@ The driver MUST be invoked while IC_ENABLE = 0 - otherwise HCNT/LCNT
@ writes are ignored silently.
@
@ Clobbers: r0-r3, r4-r5 (preserved).
@ ----------------------------------------------------------------------------
    .section .text.i2c_set_baudrate, "ax"
    .thumb_func
    .global  i2c_set_baudrate
i2c_set_baudrate:
    push    {r4, r5, r6, r7, lr}
    mov     r4, r0                          @ r4 = idx
    mov     r5, r1                          @ r5 = hz

    @ ---- Make sure the peripheral is disabled --------------------------
    bl      _i2c_base
    mov     r6, r0                          @ r6 = base
    bl      _i2c_disable
    mov     r0, r6                          @ restore r0=base after _disable

    @ ---- period_ticks = 150_000_000 / hz -------------------------------
    ldr     r1, =150000000
    udiv    r2, r1, r5                      @ r2 = period_ticks

    @ ---- HCNT = period * 4 / 10 - 8 (clamped to 8 minimum) -------------
    movs    r3, #4
    muls    r3, r3, r2
    movs    r1, #10
    udiv    r3, r3, r1                      @ r3 = period*4/10
    cmp     r3, #8
    bls     1f
    subs    r3, #8
    b       2f
1:  movs    r3, #8
2:
    @ ---- LCNT = period * 6 / 10 - 1 (clamped to 8 minimum) -------------
    movs    r7, #6
    muls    r7, r7, r2
    movs    r1, #10
    udiv    r7, r7, r1                      @ r7 = period*6/10
    cmp     r7, #1
    bls     3f
    subs    r7, #1
3:  cmp     r7, #8
    bhi     4f
    movs    r7, #8
4:
    @ ---- Decide between SS and FS based on freq ------------------------
    @ Threshold: anything >100 kHz = FS programming registers.
    ldr     r1, =100000
    cmp     r5, r1
    bls     5f                              @ <= 100 kHz -> SS
    @ FS path
    str     r3, [r6, #IC_FS_SCL_HCNT]
    str     r7, [r6, #IC_FS_SCL_LCNT]
    movs    r2, #I2C_SDA_HOLD_FS_AT_150MHZ
    @ For >= 1 MHz, use the smaller hold to keep tHD;DAT < 70 ns
    ldr     r1, =900000
    cmp     r5, r1
    bls     6f
    movs    r2, #I2C_SDA_HOLD_HS_AT_150MHZ
6:  str     r2, [r6, #IC_SDA_HOLD]
    b       7f
5:
    @ SS path
    str     r3, [r6, #IC_SS_SCL_HCNT]
    str     r7, [r6, #IC_SS_SCL_LCNT]
    movs    r2, #I2C_SDA_HOLD_FS_AT_150MHZ
    str     r2, [r6, #IC_SDA_HOLD]
7:
    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ i2c_set_slave_mode(idx, addr)
@   r0 = idx, r1 = 7-bit slave address
@
@ Disable, write IC_SAR, switch IC_CON to slave mode (clear MASTER_MODE +
@ SLAVE_DISABLE), re-enable.
@ ----------------------------------------------------------------------------
    .section .text.i2c_set_slave_mode, "ax"
    .thumb_func
    .global  i2c_set_slave_mode
i2c_set_slave_mode:
    push    {r4, r5, lr}
    mov     r4, r0
    mov     r5, r1
    bl      _i2c_base
    push    {r0}
    bl      _i2c_disable
    pop     {r0}

    @ IC_SAR
    str     r5, [r0, #IC_SAR]
    @ IC_CON = slave-mode FS (clears MASTER_MODE and SLAVE_DISABLE)
    ldr     r1, =I2C_CON_SLAVE_FS
    str     r1, [r0, #IC_CON]
    @ Re-enable
    movs    r1, #IC_ENABLE_ENABLE
    str     r1, [r0, #IC_ENABLE]
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ i2c_write_blocking(idx, addr, src, len, nostop_bool) -> r0
@   r0 = idx
@   r1 = addr  (7-bit; driver shifts into IC_TAR position 0)
@   r2 = src buffer pointer
@   r3 = len
@   [sp,#0] = nostop_bool (0 -> issue STOP on last byte; nonzero -> hold bus)
@
@ Returns:
@   r0 = bytes_written       on success
@   r0 = -1 (= 0xFFFFFFFF)   on TX_ABRT (IC_TX_ABRT_SOURCE non-zero)
@
@ Sequence:
@   1. IC_ENABLE = 0; IC_TAR = addr; IC_ENABLE = 1.
@   2. For each byte b[i]:
@        spin while !(IC_STATUS & TFNF)
@        cmd = b[i]
@        if last byte && !nostop:  cmd |= STOP
@        IC_DATA_CMD = cmd
@   3. Spin until IC_STATUS.MST_ACTIVITY == 0
@   4. Read IC_TX_ABRT_SOURCE; if non-zero, clear via IC_CLR_TX_ABRT and
@      return -1.
@
@ Clobbers: r0-r7 (callee-saved restored on return).
@ ----------------------------------------------------------------------------
    .section .text.i2c_write_blocking, "ax"
    .thumb_func
    .global  i2c_write_blocking
i2c_write_blocking:
    push    {r4, r5, r6, r7, lr}
    @ Stack layout after push: [sp,#20] = nostop_bool
    mov     r4, r2                          @ r4 = src
    mov     r5, r3                          @ r5 = len
    mov     r6, r1                          @ r6 = addr
    @ r0 = idx
    bl      _i2c_base
    mov     r7, r0                          @ r7 = base

    @ Update IC_TAR around an enable/disable cycle.
    mov     r0, r7
    bl      _i2c_disable
    str     r6, [r7, #IC_TAR]
    movs    r1, #IC_ENABLE_ENABLE
    str     r1, [r7, #IC_ENABLE]

    @ ---- Push bytes ---------------------------------------------------
    @ r5 = remaining count, r4 = src pointer
    @ Use r6 for the cmd word; r3 = nostop_bool.
    ldr     r3, [sp, #20]                   @ r3 = nostop_bool
    movs    r0, #0                          @ r0 = bytes_written counter
    cbz     r5, 9f                          @ zero-length write -> just bus probe

.Lwrite_loop:
    @ Spin until TX FIFO not full
1:  ldr     r1, [r7, #IC_STATUS]
    lsls    r2, r1, #(31 - 1)               @ shift TFNF (bit1) into N
    bpl     1b

    @ Build cmd byte
    ldrb    r6, [r4], #1                    @ next data byte, post-incr
    @ If this is the last byte and nostop==0, set STOP
    cmp     r5, #1
    bne     2f
    cmp     r3, #0
    bne     2f
    movw    r1, #IC_DATA_CMD_STOP
    orrs    r6, r1
2:  str     r6, [r7, #IC_DATA_CMD]
    adds    r0, #1
    subs    r5, #1
    bne     .Lwrite_loop

9:
    @ ---- Wait for the master FSM to go idle ---------------------------
    @ MST_ACTIVITY = bit5; spins until 0.
3:  ldr     r1, [r7, #IC_STATUS]
    lsls    r2, r1, #(31 - 5)               @ MST_ACTIVITY -> N
    bmi     3b

    @ ---- Check IC_TX_ABRT_SOURCE --------------------------------------
    ldr     r1, [r7, #IC_TX_ABRT_SOURCE]
    cmp     r1, #0
    beq     4f
    @ Clear abort by reading IC_CLR_TX_ABRT
    ldr     r2, [r7, #IC_CLR_TX_ABRT]
    movs    r0, #0
    mvns    r0, r0                          @ r0 = 0xFFFFFFFF (= -1)
4:
    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ i2c_read_blocking(idx, addr, dst, len, nostop_bool) -> r0
@   r0 = idx, r1 = addr, r2 = dst, r3 = len, [sp,#0] = nostop_bool
@
@ Returns:
@   r0 = bytes_read           on success
@   r0 = -1                   on TX_ABRT
@
@ Strategy (fits the spec's "push len reads into TX FIFO; pop bytes from
@ RX FIFO into dst" instruction):
@   1. IC_ENABLE=0, IC_TAR=addr, IC_ENABLE=1.
@   2. Issue len reads into TX FIFO with CMD=1; last one carries STOP if
@      !nostop.  After each push, drain any RX bytes that have arrived
@      (avoids blocking if the FIFO fills before we push the last cmd).
@   3. Drain remaining bytes from RX FIFO until len received.
@   4. Wait MST_ACTIVITY=0.  Check IC_TX_ABRT_SOURCE.
@
@ Clobbers: r0-r7.
@ ----------------------------------------------------------------------------
    .section .text.i2c_read_blocking, "ax"
    .thumb_func
    .global  i2c_read_blocking
i2c_read_blocking:
    push    {r4, r5, r6, r7, lr}
    @ Stack layout: [sp,#20] = nostop_bool
    mov     r4, r2                          @ r4 = dst
    mov     r5, r3                          @ r5 = len (count to issue)
    mov     r6, r1                          @ r6 = addr
    bl      _i2c_base
    mov     r7, r0                          @ r7 = base

    mov     r0, r7
    bl      _i2c_disable
    str     r6, [r7, #IC_TAR]
    movs    r1, #IC_ENABLE_ENABLE
    str     r1, [r7, #IC_ENABLE]

    ldr     r3, [sp, #20]                   @ r3 = nostop_bool
    movs    r0, #0                          @ r0 = bytes_read counter
    cbz     r5, .Lread_done

    @ r6 = remaining commands to issue (starts == r5)
    mov     r6, r5

.Lread_loop:
    @ ---- Push READ command if we still have any to issue ---------------
    cbz     r6, .Lread_drain_only
    @ Spin until TX FIFO not full
5:  ldr     r1, [r7, #IC_STATUS]
    lsls    r2, r1, #(31 - 1)               @ TFNF -> N
    bpl     5b

    @ Build CMD = READ_CMD bit; last command may carry STOP
    movw    r1, #IC_DATA_CMD_CMD
    cmp     r6, #1
    bne     6f
    cmp     r3, #0
    bne     6f
    movw    r2, #IC_DATA_CMD_STOP
    orrs    r1, r2
6:  str     r1, [r7, #IC_DATA_CMD]
    subs    r6, #1

.Lread_drain_only:
    @ ---- Drain whatever the RX FIFO has now ----------------------------
    cmp     r0, r5
    beq     .Lread_done
7:  ldr     r1, [r7, #IC_STATUS]
    lsls    r2, r1, #(31 - 3)               @ RFNE (bit3) -> N
    bpl     8f                              @ no byte available right now
    ldr     r1, [r7, #IC_DATA_CMD]          @ low byte = received data
    strb    r1, [r4], #1
    adds    r0, #1
    cmp     r0, r5
    bne     7b
    b       .Lread_done
8:
    @ Need more bytes - go round again (issue another cmd if any left,
    @ then try to drain again).
    cmp     r6, #0
    bne     .Lread_loop
    @ Out of commands but still missing bytes - keep spinning on RFNE.
    b       7b

.Lread_done:
    @ ---- Wait MST_ACTIVITY=0 ------------------------------------------
3:  ldr     r1, [r7, #IC_STATUS]
    lsls    r2, r1, #(31 - 5)
    bmi     3b

    @ ---- Check abort --------------------------------------------------
    ldr     r1, [r7, #IC_TX_ABRT_SOURCE]
    cmp     r1, #0
    beq     4f
    ldr     r2, [r7, #IC_CLR_TX_ABRT]
    movs    r0, #0
    mvns    r0, r0
4:
    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ i2c_set_pins(idx, sda_pin, scl_pin)
@   r0 = idx, r1 = sda_pin (0..47), r2 = scl_pin
@
@ Sets both pins to GPIO_FUNC_I2C (=3) and enables the internal pull-up.
@ For real hardware you should still wire external 4.7 kOhm pull-ups; the
@ internal ~50 kOhm pulls are too weak to satisfy I2C rise-time specs at
@ 400 kHz+, but they're fine for bench bring-up at 100 kHz.
@
@ Note: idx is currently unused (the GPIO mux already encodes which I2C
@ instance the pin maps to via the pin number).  We accept it for API
@ symmetry with i2c_init / i2c_set_baudrate and to leave room for a future
@ "validate the pin actually exposes I2Cn" check.
@ ----------------------------------------------------------------------------
    .section .text.i2c_set_pins, "ax"
    .thumb_func
    .global  i2c_set_pins
i2c_set_pins:
    push    {r4, r5, lr}
    mov     r4, r1                          @ r4 = sda_pin
    mov     r5, r2                          @ r5 = scl_pin

    @ SDA: function then pull-up
    mov     r0, r4
    movs    r1, #3                          @ GPIO_FUNC_I2C
    bl      gpio_set_function
    mov     r0, r4
    bl      gpio_pull_up

    @ SCL: function then pull-up
    mov     r0, r5
    movs    r1, #3
    bl      gpio_set_function
    mov     r0, r5
    bl      gpio_pull_up

    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ i2c_set_irqs_enabled(idx, mask)
@   r0 = idx, r1 = mask  (combination of IC_INTR_* bits)
@   IC_INTR_MASK = mask  (plain RW; previous value clobbered).
@ ----------------------------------------------------------------------------
    .section .text.i2c_set_irqs_enabled, "ax"
    .thumb_func
    .global  i2c_set_irqs_enabled
i2c_set_irqs_enabled:
    push    {r4, lr}
    mov     r4, r1
    bl      _i2c_base
    str     r4, [r0, #IC_INTR_MASK]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ i2c_clear_irq(idx, which)
@   r0 = idx, r1 = which (one of IC_INTR_* bits)
@
@ DesignWare clears each irq via a *read* of the matching IC_CLR_<x>
@ register.  IC_CLR_INTR (offset 0x40) clears all combined sources at once;
@ we use that when which == 0 (the convenient "clear everything").  For a
@ specific bit, we map to the per-source register.
@
@ Bits handled (bit position -> offset):
@   0 RX_UNDER  -> 0x44
@   1 RX_OVER   -> 0x48
@   3 TX_OVER   -> 0x4C
@   5 RD_REQ    -> 0x50
@   6 TX_ABRT   -> 0x54
@   7 RX_DONE   -> 0x58
@   8 ACTIVITY  -> 0x5C
@   9 STOP_DET  -> 0x60
@  10 START_DET -> 0x64
@   any other bit (incl. RX_FULL, TX_EMPTY, GEN_CALL, RESTART_DET) is
@   level-driven and self-clears when the underlying condition resolves;
@   we read IC_CLR_INTR as a fallback.
@ ----------------------------------------------------------------------------
    .section .text.i2c_clear_irq, "ax"
    .thumb_func
    .global  i2c_clear_irq
i2c_clear_irq:
    push    {r4, lr}
    mov     r4, r1                          @ r4 = which
    bl      _i2c_base                       @ r0 = base
    cbz     r4, .Lclr_combined

    @ Map the bit to a CLR offset.
    movs    r2, #IC_INTR_RX_UNDER
    cmp     r4, r2
    bne     1f
    movs    r3, #IC_CLR_RX_UNDER
    b       .Lclr_do
1:  movs    r2, #IC_INTR_RX_OVER
    cmp     r4, r2
    bne     2f
    movs    r3, #IC_CLR_RX_OVER
    b       .Lclr_do
2:  movs    r2, #IC_INTR_TX_OVER
    cmp     r4, r2
    bne     3f
    movs    r3, #IC_CLR_TX_OVER
    b       .Lclr_do
3:  movs    r2, #IC_INTR_RD_REQ
    cmp     r4, r2
    bne     4f
    movs    r3, #IC_CLR_RD_REQ
    b       .Lclr_do
4:  movs    r2, #IC_INTR_TX_ABRT
    cmp     r4, r2
    bne     5f
    movs    r3, #IC_CLR_TX_ABRT
    b       .Lclr_do
5:  movs    r2, #IC_INTR_RX_DONE
    cmp     r4, r2
    bne     6f
    movs    r3, #IC_CLR_RX_DONE
    b       .Lclr_do
6:  movs    r2, #IC_INTR_ACTIVITY
    cmp     r4, r2
    bne     7f
    movs    r3, #IC_CLR_ACTIVITY
    b       .Lclr_do
7:  movw    r2, #IC_INTR_STOP_DET
    cmp     r4, r2
    bne     8f
    movs    r3, #IC_CLR_STOP_DET
    b       .Lclr_do
8:  movw    r2, #IC_INTR_START_DET
    cmp     r4, r2
    bne     .Lclr_combined
    movs    r3, #IC_CLR_START_DET

.Lclr_do:
    ldr     r1, [r0, r3]                    @ side-effect: clears the source
    pop     {r4, pc}

.Lclr_combined:
    movs    r3, #IC_CLR_INTR
    ldr     r1, [r0, r3]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ i2c_set_dma_enabled(idx, tx, rx)
@   r0 = idx, r1 = tx (bool), r2 = rx (bool)
@   IC_DMA_CR = (rx ? RDMAE : 0) | (tx ? TDMAE : 0)
@ ----------------------------------------------------------------------------
    .section .text.i2c_set_dma_enabled, "ax"
    .thumb_func
    .global  i2c_set_dma_enabled
i2c_set_dma_enabled:
    push    {r4, lr}
    mov     r4, r1
    @ r2 stays
    mov     r1, r2
    @ r1 = rx, r4 = tx
    @ Build the IC_DMA_CR value: bit0 = rx, bit1 = tx.
    movs    r2, #0
    cmp     r1, #0
    beq     1f
    orrs    r2, r2, #IC_DMA_CR_RDMAE
1:  cmp     r4, #0
    beq     2f
    orrs    r2, r2, #IC_DMA_CR_TDMAE
2:  @ r0 = idx
    bl      _i2c_base
    str     r2, [r0, #IC_DMA_CR]
    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ i2c_get_status(idx) -> r0
@   r0 = idx
@   Returns IC_STATUS as-is.
@ ----------------------------------------------------------------------------
    .section .text.i2c_get_status, "ax"
    .thumb_func
    .global  i2c_get_status
i2c_get_status:
    push    {lr}
    bl      _i2c_base
    ldr     r0, [r0, #IC_STATUS]
    pop     {pc}
