@ =============================================================================
@ timer.S - RP2350 TIMER0 / TIMER1 driver (M3-B core peripherals)
@
@ Datasheet ref: RP2350 sec 12.8.
@
@ Public API:
@   timer_resets_enable                                       - bring TIMER0+1 OOR
@   timer_init                                                - timer_resets_enable + ack
@   time_us_64       () -> r0=lo, r1=hi                       - 64-bit us since boot
@   time_us_32       () -> r0                                 - low 32 bits only
@   delay_us         (r0=us)                                  - busy wait, 32-bit math
@   delay_ms         (r0=ms)                                  - delay_us(ms*1000)
@   alarm_set        (r0=timer_idx, r1=alarm_idx,
@                     r2=target_lo, r3=target_hi)             - arms alarm, low compare
@   alarm_cancel     (r0=timer_idx, r1=alarm_idx)             - clear ARMED bit
@   alarm_clear_irq  (r0=timer_idx, r1=alarm_idx)             - W1C in INTR
@
@ The 64-bit read protocol:
@   * Reading TIMELR latches TIMEHR; you MUST read TIMELR first then TIMEHR.
@   * TIMERAWL/TIMERAWH skip the latch (use only when 32-bit precision is OK).
@
@ Alarm compare quirk: ARMn compares only the low 32 bits of TIME.  For
@ short windows (< ~71 minutes) this is fine; for longer waits the caller
@ must rearm in the ISR.
@
@ Cycle budgets (release ARMv8-M, no wait states):
@   time_us_32     : ~3 cycles  (1 ldr + return)
@   time_us_64     : ~7 cycles  (latch + 2 ldrs + return)
@   delay_us(N)    : ~5 cycles per inner spin iteration
@   alarm_set      : ~10 cycles (compute base+offset, store, clear INTR)
@   alarm_cancel   : ~6 cycles
@ =============================================================================

    .include "rp2350.inc"
    .include "timer.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----- Internal helpers (file-scope) -----------------------------------------
@ timer_idx (r0) -> base address (r0):
@   0 => TIMER0_BASE, anything else => TIMER1_BASE.
@ Implemented as a macro to keep callers branchless.
.macro TIMER_BASE_FROM_IDX rd, ridx, scratch
    @ rd = (ridx == 0) ? TIMER0_BASE : TIMER1_BASE
    @ Compute TIMER0_BASE + (ridx != 0) * (TIMER1_BASE - TIMER0_BASE)
    @ but easier: ldr both, csel via cmp/itt.
    cmp     \ridx, #0
    ldr     \rd, =TIMER0_BASE
    ldr     \scratch, =TIMER1_BASE
    it      ne
    movne   \rd, \scratch
.endm

@ ----------------------------------------------------------------------------
@ timer_resets_enable - clear RESETS bits 23 (timer0) and 24 (timer1)
@ via the RESETS_RESET CLR alias, then spin until RESET_DONE reflects it.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.timer_resets_enable, "ax"
    .thumb_func
    .global  timer_resets_enable
timer_resets_enable:
    @ mask = (1<<23)|(1<<24) = 0x01800000
    movs    r1, #1
    lsls    r2, r1, #RESETS_timer0      @ 1<<23
    lsls    r3, r1, #RESETS_timer1      @ 1<<24
    orrs    r2, r3                      @ r2 = mask

    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r2, [r0]

    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r1, [r0]
    ands    r1, r2
    cmp     r1, r2
    bne     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ timer_init - alias for timer_resets_enable.
@
@ The TICKS sub-block for both timers was started by M2's tick_init at
@ 1 MHz.  Once the resets are released the counters begin to free-run
@ immediately, so there is nothing else to do here.
@ ----------------------------------------------------------------------------
    .section .text.timer_init, "ax"
    .thumb_func
    .global  timer_init
timer_init:
    b       timer_resets_enable

@ ----------------------------------------------------------------------------
@ time_us_64 - 64-bit microseconds since boot (TIMER0).
@ Output: r0 = low 32, r1 = high 32.
@
@ Per the latch protocol: read TIMELR first (this also latches TIMEHR), then
@ read TIMEHR.  Otherwise the high half could increment between the two
@ reads and we'd see a 0xFFFFFFFF -> 0x00000000 carry inversion.
@ ~7 cycles.
@ ----------------------------------------------------------------------------
    .section .text.time_us_64, "ax"
    .thumb_func
    .global  time_us_64
time_us_64:
    ldr     r2, =TIMER0_BASE
    ldr     r0, [r2, #TIMER_TIMELR]     @ latches HI
    ldr     r1, [r2, #TIMER_TIMEHR]
    bx      lr

@ ----------------------------------------------------------------------------
@ time_us_32 - low 32 bits of TIMER0.
@ Output: r0 = TIMERAWL (no latch needed for a 32-bit-only read).
@ ~3 cycles.
@ ----------------------------------------------------------------------------
    .section .text.time_us_32, "ax"
    .thumb_func
    .global  time_us_32
time_us_32:
    ldr     r0, =TIMER0_BASE + TIMER_TIMERAWL
    ldr     r0, [r0]
    bx      lr

@ ----------------------------------------------------------------------------
@ delay_us - busy-wait for r0 microseconds using TIMER0 TIMERAWL.
@ Input  : r0 = us (treated as 32-bit unsigned)
@ Clobbers: r0-r3.
@
@ Algorithm:
@   start = TIMERAWL
@   while ((TIMERAWL - start) < us): spin
@ Wrap-safe because we use unsigned subtraction; works for delays up to
@ ~71 minutes (2^32 us).  For longer delays use 64-bit.
@ ----------------------------------------------------------------------------
    .section .text.delay_us, "ax"
    .thumb_func
    .global  delay_us
delay_us:
    ldr     r1, =TIMER0_BASE + TIMER_TIMERAWL
    ldr     r2, [r1]                    @ start
1:  ldr     r3, [r1]                    @ now
    subs    r3, r3, r2                  @ elapsed (unsigned)
    cmp     r3, r0
    blo     1b                          @ while elapsed < us
    bx      lr

@ ----------------------------------------------------------------------------
@ delay_ms - delay_us(ms * 1000)
@ Input  : r0 = ms (treated as 32-bit unsigned)
@ Clobbers: r0-r3.
@
@ ms * 1000 may overflow 32 bits (max ~4.29 * 10^6 ms = ~71 min). The caller
@ is responsible for not exceeding that.
@ ----------------------------------------------------------------------------
    .section .text.delay_ms, "ax"
    .thumb_func
    .global  delay_ms
delay_ms:
    movw    r1, #1000
    muls    r0, r1, r0
    b       delay_us

@ ----------------------------------------------------------------------------
@ alarm_set - schedule an alarm on TIMER<idx> alarm <a>.
@ Input :
@   r0 = timer_idx (0 = TIMER0, 1 = TIMER1)
@   r1 = alarm_idx (0..3)
@   r2 = target_us low 32 (only this is compared by HW)
@   r3 = target_us high 32 (ignored - hardware compare is 32-bit only)
@ Clobbers: r0-r3, r12.
@
@ Writing ALARMn auto-arms the alarm in the ARMED register.  We also clear
@ any stale interrupt flag for that alarm via the INTR W1C alias so the
@ ISR doesn't fire spuriously on the first iteration.
@ ----------------------------------------------------------------------------
    .section .text.alarm_set, "ax"
    .thumb_func
    .global  alarm_set
alarm_set:
    push    {r4, lr}
    @ r4 = TIMER<idx>_BASE
    TIMER_BASE_FROM_IDX r4, r0, r12

    @ Clear any pending IRQ for this alarm: INTR W1C bit (1<<a)
    movs    r0, #1
    lsls    r0, r0, r1                  @ r0 = (1 << alarm_idx)
    str     r0, [r4, #TIMER_INTR]       @ W1C clears bit

    @ Compute ALARM register address: base + 0x10 + a*4
    @ (alarm_idx range checking is the caller's responsibility)
    lsls    r12, r1, #2                 @ a*4
    add     r12, r12, #TIMER_ALARM0     @ 0x10 + a*4
    str     r2, [r4, r12]               @ ALARMn = target_lo (auto-arms)

    @ (target_hi is intentionally ignored - the comparator is 32-bit only.
    @ Callers building delays > 71 min must rearm in the ISR.)

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ alarm_cancel - disarm alarm <a> on timer <idx>.
@ Input  : r0 = timer_idx, r1 = alarm_idx (0..3)
@ Clobbers: r0-r3, r12.
@
@ ARMED is RW1C: writing 1 to a bit clears (disarms) it.
@ ----------------------------------------------------------------------------
    .section .text.alarm_cancel, "ax"
    .thumb_func
    .global  alarm_cancel
alarm_cancel:
    push    {r4, lr}
    TIMER_BASE_FROM_IDX r4, r0, r12

    movs    r2, #1
    lsls    r2, r2, r1                  @ 1 << alarm_idx
    str     r2, [r4, #TIMER_ARMED]      @ W1C disarms

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ alarm_clear_irq - clear the IRQ-flag bit for alarm <a> on timer <idx>.
@ Input  : r0 = timer_idx, r1 = alarm_idx (0..3)
@ Clobbers: r0-r3, r12.
@ ----------------------------------------------------------------------------
    .section .text.alarm_clear_irq, "ax"
    .thumb_func
    .global  alarm_clear_irq
alarm_clear_irq:
    push    {r4, lr}
    TIMER_BASE_FROM_IDX r4, r0, r12

    movs    r2, #1
    lsls    r2, r2, r1                  @ 1 << alarm_idx
    str     r2, [r4, #TIMER_INTR]       @ W1C clears

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ alarm_enable_irq - set the INTE bit for alarm <a> on timer <idx>.
@ Input  : r0 = timer_idx, r1 = alarm_idx (0..3)
@ Clobbers: r0-r3, r12.
@
@ Uses the ATOMIC_SET alias so we never lose other enabled alarms.
@ ----------------------------------------------------------------------------
    .section .text.alarm_enable_irq, "ax"
    .thumb_func
    .global  alarm_enable_irq
alarm_enable_irq:
    push    {r4, lr}
    TIMER_BASE_FROM_IDX r4, r0, r12
    add     r4, r4, #ATOMIC_SET

    movs    r2, #1
    lsls    r2, r2, r1
    str     r2, [r4, #TIMER_INTE]

    pop     {r4, pc}
