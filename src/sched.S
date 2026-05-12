@ =============================================================================
@ sched.S - NVIC-priority kernel (QV-style) for rp-asm.
@
@ Concept: every "task" is an NVIC interrupt handler living in a slot
@ above the hardware peripherals (default IRQ 48..55).  `task_post(id)`
@ is one STR to NVIC_ISPR — the CPU's NVIC tail-chains into the highest-
@ priority pending task, runs it to completion, and re-enters WFI when
@ nothing is pending.
@
@ Public API:
@   sched_init                                  Clear table, enable SEVONPEND
@   task_create(r0=id, r1=fn, r2=prio)         Install fn @ vector slot,
@                                              set priority, NVIC-enable
@   task_post(r0=id)                            STR to NVIC_ISPR — 5 cycles
@   task_clear(r0=id)                           Cancel a pending post
@   sched_run                                   cpsie i; loop { wfi }
@   critical_enter() -> r0                      MRS r0, PRIMASK; CPSID i
@   critical_exit(r0)                           MSR PRIMASK, r0
@
@ Cycle budgets (Cortex-M33, no wait states):
@   task_post:           5 cycles  (compute reg + bit + STR)
@   task_create:        ~20 cycles (3 stores via nvic_install_handler + IPR + ISER)
@   sched_run idle:     0 cycles in WFI, 12 cycles to first task instr on wake
@   critical_enter:      3 cycles
@   critical_exit:       2 cycles
@
@ Limits / contract for task bodies:
@   - Tasks are stackless ISR-like functions: they share the main stack.
@   - Tasks must follow AAPCS, push r4-r11 if used (see docs/calling.md).
@   - Tasks run to completion; no `sched_sleep_ms` blocking primitive.
@     To "wait", arm a TIMER0 alarm whose handler posts you back.
@   - To pass data into a task, write to a global before task_post.
@     Tasks at the same priority can't race (run-to-completion); tasks
@     at different priorities may need critical_enter/exit around shared
@     state, or use lock-free SPSC queues.
@ =============================================================================

    .include "sched.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ sched_init
@   Clears any leftover pending bits in the task slot range, sets
@   SCB.SCR.SEVONPEND so WFI wakes on any pending IRQ (even masked ones,
@   useful if you ever raise PRIMASK over WFI).
@   Clobbers: r0-r2.
@ ----------------------------------------------------------------------------
    .section .text.sched_init, "ax"
    .thumb_func
    .global  sched_init
sched_init:
    @ Clear pending bits for all MAX_TASKS slots — there's no spec'd
    @ "fresh boot" guarantee, and re-init from a stuck state should work.
    movs    r0, #0xFF                       @ low 8 task bits for our default base 48
    movt    r0, #0                          @ ICPR1 covers IRQ 32..63; bits 16..23 = IRQs 48..55
    lsls    r0, #16                         @ r0 = 0x00FF0000
    ldr     r1, =NVIC_ICPR_BASE + 4         @ ICPR1 (IRQs 32..63)
    str     r0, [r1]

    @ SCB.SCR.SEVONPEND = 1
    ldr     r1, =SCB_SCR
    ldr     r0, [r1]
    orrs    r0, r0, #SCB_SCR_SEVONPEND
    str     r0, [r1]
    bx      lr

@ ----------------------------------------------------------------------------
@ task_create(id, fn, prio)
@   r0 = task id (0..MAX_TASKS-1)
@   r1 = handler function address (Thumb-encoded; we OR the LSB)
@   r2 = priority byte (0..255).  Lower numeric = higher priority.
@        Only the top NVIC_PRIO_BITS are implemented by the chip.
@
@   Effect:
@     1. _vectors[16 + IRQ_N] = fn | 1     (we delegate to nvic_install_handler)
@     2. NVIC_IPR[IRQ_N] (byte) = prio
@     3. NVIC_ISER[IRQ_N / 32] |= (1 << (IRQ_N % 32))
@
@   Clobbers: r0-r3, lr (via bl).
@ ----------------------------------------------------------------------------
    .section .text.task_create, "ax"
    .thumb_func
    .global  task_create
task_create:
    push    {r4, r5, r6, lr}
    mov     r4, r2                          @ save prio
    adds    r0, r0, #SCHED_BASE_IRQ         @ r0 = IRQ_N  (also caller's id+base)
    mov     r5, r0                          @ keep IRQ_N

    @ Install handler in vector slot.  nvic_install_handler takes
    @ (r0=irq_num, r1=handler).
    bl      nvic_install_handler

    @ Set priority: byte at NVIC_IPR_BASE + IRQ_N
    ldr     r0, =NVIC_IPR_BASE
    strb    r4, [r0, r5]

    @ Enable: ISER[IRQ_N / 32] |= (1 << (IRQ_N % 32))
    mov     r0, r5                          @ IRQ_N
    bl      nvic_enable_irq
    pop     {r4, r5, r6, pc}

@ ----------------------------------------------------------------------------
@ task_post(id)
@   r0 = task id.  STR (1 << (IRQ_N % 32)) to NVIC_ISPR[IRQ_N / 32].
@   Safe from ISRs.  5 cycles.
@ ----------------------------------------------------------------------------
    .section .text.task_post, "ax"
    .thumb_func
    .global  task_post
task_post:
    adds    r0, r0, #SCHED_BASE_IRQ         @ r0 = IRQ_N
    @ bank = IRQ_N >> 5; bit = 1 << (IRQ_N & 31)
    lsrs    r1, r0, #5                      @ r1 = bank index
    and     r2, r0, #31
    movs    r0, #1
    lsls    r0, r2                          @ r0 = bit mask
    ldr     r3, =NVIC_ISPR_BASE
    str     r0, [r3, r1, lsl #2]
    bx      lr

@ ----------------------------------------------------------------------------
@ task_post_n(mask)
@   r0 = bitmask of task ids (bit i = task i).  Posts all set bits in one
@   STR to NVIC_ISPR.  Requires every task slot to live in the same NVIC
@   bank — true when MAX_TASKS=8 and SCHED_BASE_IRQ=48 (bits 16..23 of
@   bank 1).  6 cycles total.
@
@   Example: task_post_n(0x05) posts tasks 0 and 2.
@ ----------------------------------------------------------------------------
    .equ _SCHED_ISPR_BANK,   (SCHED_BASE_IRQ / 32)
    .equ _SCHED_ISPR_SHIFT,  (SCHED_BASE_IRQ % 32)

    .section .text.task_post_n, "ax"
    .thumb_func
    .global  task_post_n
task_post_n:
    and     r0, r0, #((1 << MAX_TASKS) - 1)
    lsls    r0, #_SCHED_ISPR_SHIFT
    ldr     r1, =NVIC_ISPR_BASE + (_SCHED_ISPR_BANK * 4)
    str     r0, [r1]
    bx      lr

@ ----------------------------------------------------------------------------
@ task_clear(id) - cancel a pending post before the task runs.
@   No-op if the task is already running or not pending.
@ ----------------------------------------------------------------------------
    .section .text.task_clear, "ax"
    .thumb_func
    .global  task_clear
task_clear:
    adds    r0, r0, #SCHED_BASE_IRQ
    lsrs    r1, r0, #5
    and     r2, r0, #31
    movs    r0, #1
    lsls    r0, r2
    ldr     r3, =NVIC_ICPR_BASE
    str     r0, [r3, r1, lsl #2]
    bx      lr

@ ----------------------------------------------------------------------------
@ sched_run - enable IRQs, then WFI loop in thread mode.
@   NEVER returns; the application's `main` should end with `b sched_run`
@   after task_create()s + initial task_post()s.
@   While WFI is asserted, the core sleeps; any task_post that raises an
@   enabled NVIC line wakes the core and the highest-priority pending
@   handler runs.
@ ----------------------------------------------------------------------------
    .section .text.sched_run, "ax"
    .thumb_func
    .global  sched_run
sched_run:
    cpsie   i
1:  wfi
    b       1b

@ ----------------------------------------------------------------------------
@ critical_enter / critical_exit - PRIMASK-based critical section.
@   Disables ALL IRQs (including the highest hardware priority).  Use
@   sparingly — for fine-grained mutual exclusion, use BASEPRI instead.
@   Returns previous PRIMASK in r0 so nested sections compose.
@ ----------------------------------------------------------------------------
    .section .text.critical_enter, "ax"
    .thumb_func
    .global  critical_enter
critical_enter:
    mrs     r0, PRIMASK
    cpsid   i
    bx      lr

    .section .text.critical_exit, "ax"
    .thumb_func
    .global  critical_exit
critical_exit:
    msr     PRIMASK, r0
    bx      lr

@ ----------------------------------------------------------------------------
@ critical_enter_basepri(prio) -> r0 = previous BASEPRI
@   r0 = priority threshold (same encoding as task_create's prio arg).
@   Masks IRQs at or below this priority while allowing strictly-higher
@   priorities through.  Use this instead of critical_enter when you want
@   the top-priority task to keep preempting.
@
@   Example:
@     critical_enter_basepri(0x40)  --> tasks at 0x40, 0x80, 0xC0 masked;
@                                       tasks at 0x00 still preempt.
@
@   Cortex-M33 BASEPRI semantics (ARMv8-M §B3.4.10):
@     - BASEPRI = 0 disables masking (default).
@     - BASEPRI = N (N != 0) masks exceptions with priority value >= N.
@     - Only the top NVIC_PRIO_BITS of the byte are implemented; lower
@       bits read as zero.
@
@   3 cycles.
@ ----------------------------------------------------------------------------
    .section .text.critical_enter_basepri, "ax"
    .thumb_func
    .global  critical_enter_basepri
critical_enter_basepri:
    mrs     r1, BASEPRI
    msr     BASEPRI, r0
    mov     r0, r1
    bx      lr

@ ----------------------------------------------------------------------------
@ critical_exit_basepri(saved)
@   r0 = the value returned by critical_enter_basepri.  Restores.
@   2 cycles.
@ ----------------------------------------------------------------------------
    .section .text.critical_exit_basepri, "ax"
    .thumb_func
    .global  critical_exit_basepri
critical_exit_basepri:
    msr     BASEPRI, r0
    bx      lr
