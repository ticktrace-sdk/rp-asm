@ =============================================================================
@ dma.S - RP2350 DMA controller driver (M3-C).
@
@ Datasheet ref: RP2350 datasheet rev 0.3 (Aug 2024) section 12.6.
@
@ Public API (AAPCS - r0..r3 are arg registers; r4..r11 callee-saved):
@
@   dma_init                                       — bring DMA out of reset
@   dma_resets_enable                              — alias for dma_init
@
@   dma_channel_set_read(ch, addr)                 — AL1_READ_ADDR (no trig)
@   dma_channel_set_write(ch, addr)                — AL1_WRITE_ADDR (no trig)
@   dma_channel_set_trans_count(ch, count)         — AL1 TRANS_COUNT (no trig)
@   dma_channel_set_ctrl(ch, ctrl)                 — AL1_CTRL (no trig)
@
@   dma_channel_configure(ch, ctrl, read, write, count, trig)
@                                                  — convenience: 5 stores;
@                                                    if trig != 0, end with
@                                                    CTRL_TRIG (alias 0).
@                                                    args 5/6 on stack.
@
@   dma_channel_start(ch)                          — MULTI_CHAN_TRIGGER = 1<<ch
@   dma_channel_wait_for_finish(ch)                — spin while CTRL.BUSY = 1
@   dma_channel_abort(ch)                          — CHAN_ABORT = 1<<ch; spin
@                                                    until ABORT readback clears
@
@   dma_channel_irq_enable(ch, aggregator)         — INTE[a] |= 1<<ch (atomic SET)
@   dma_channel_acknowledge_irq(ch, aggregator)    — INTR[a] write 1<<ch (W1C)
@
@   dma_sniff_enable(ch, mode)                     — SNIFF_CTRL.EN=1, DMACH=ch,
@                                                    CALC=mode.  Also pre-zeros
@                                                    SNIFF_DATA so caller sees a
@                                                    clean accumulator.
@   dma_sniff_get_data() -> r0                     — read SNIFF_DATA
@
@ Cycle budgets (real silicon, no wait states; APB stores are 2 cycles each
@ on the M33+APB bridge but back-to-back stores can overlap):
@
@   dma_channel_configure (no trig): ~12 cycles (5 stores + frame teardown)
@   dma_channel_configure (trig):    ~14 cycles (5 stores; last is CTRL_TRIG)
@   dma_channel_start:               2 cycles (single store via SET alias)
@   dma_channel_wait_for_finish:     3 cycles per spin (ldr / tst / bne)
@
@ All channel-base computes use a 6-bit shift (channel * 0x40); we keep the
@ shifted base in a callee-saved register inside the helpers so the per-channel
@ funcs don't have to recompute it for each store.
@ =============================================================================

    .include "rp2350.inc"
    .include "dma.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ dma_init / dma_resets_enable - bring the DMA block out of reset.
@
@ Writes (1 << RESETS_dma) to the RESETS_RESET CLR alias and spins until
@ RESETS_RESET_DONE shows the bit set.
@
@ Clobbers: r0-r2.  ~10 cycles + reset settle (a handful of clk_sys cycles).
@ ----------------------------------------------------------------------------
    .section .text.dma_init, "ax"
    .thumb_func
    .global  dma_init
    .global  dma_resets_enable
dma_init:
dma_resets_enable:
    movs    r1, #1
    lsls    r1, #RESETS_dma                @ r1 = 1 << 2 = 4

    @ Atomic CLR on RESETS_RESET clears the bit (= deassert reset).
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]

    @ Spin until RESET_DONE shows the bit set.
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ Helper: compute the channel base address.
@   Input:  r0 = channel index (0..15)
@   Output: r1 = DMA_BASE + ch * 0x40
@   Clobbers: r1, r2.
@
@ Inlined into the per-channel setters (3 instructions each).  We keep this
@ pattern duplicated rather than calling a sub-function so each setter stays
@ at ~3-4 instructions total.
@ ----------------------------------------------------------------------------

@ ----------------------------------------------------------------------------
@ dma_channel_set_read(ch, addr) - write AL1_READ_ADDR (no trigger).
@   r0 = ch, r1 = addr
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_set_read, "ax"
    .thumb_func
    .global  dma_channel_set_read
dma_channel_set_read:
    ldr     r2, =DMA_BASE
    lsls    r3, r0, #6                     @ r3 = ch * 0x40
    add     r2, r3                         @ r2 = channel base
    str     r1, [r2, #DMA_CH_AL1_READ_ADDR]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_set_write(ch, addr) - write AL1_WRITE_ADDR (no trigger).
@   r0 = ch, r1 = addr
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_set_write, "ax"
    .thumb_func
    .global  dma_channel_set_write
dma_channel_set_write:
    ldr     r2, =DMA_BASE
    lsls    r3, r0, #6
    add     r2, r3
    str     r1, [r2, #DMA_CH_AL1_WRITE_ADDR]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_set_trans_count(ch, count) - write AL1 TRANS_COUNT (no trigger).
@   r0 = ch, r1 = count
@ Note: the AL1 alias places TRANS_COUNT_TRIG at offset 0x1C; *that* writes
@ trigger.  To set TRANS_COUNT without triggering, write the canonical
@ TRANS_COUNT register at offset 0x08 (alias 0 layout).  Both alias 0 and
@ AL2 expose TRANS_COUNT at non-trigger offsets; we use 0x08.
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_set_trans_count, "ax"
    .thumb_func
    .global  dma_channel_set_trans_count
dma_channel_set_trans_count:
    ldr     r2, =DMA_BASE
    lsls    r3, r0, #6
    add     r2, r3
    str     r1, [r2, #DMA_CH_TRANS_COUNT]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_set_ctrl(ch, ctrl) - write AL1_CTRL (no trigger).
@   r0 = ch, r1 = ctrl
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_set_ctrl, "ax"
    .thumb_func
    .global  dma_channel_set_ctrl
dma_channel_set_ctrl:
    ldr     r2, =DMA_BASE
    lsls    r3, r0, #6
    add     r2, r3
    str     r1, [r2, #DMA_CH_AL1_CTRL]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_configure(ch, ctrl, read, write, count, trigger_bool)
@   r0 = ch
@   r1 = ctrl
@   r2 = read
@   r3 = write
@   [sp,#0] = count
@   [sp,#4] = trigger_bool   (0 = configure only; non-zero = trigger)
@
@ Strategy:
@   * Always write READ_ADDR / WRITE_ADDR / TRANS_COUNT first via the canonical
@     (alias 0) offsets - these never trigger.
@   * If trigger_bool == 0: write CTRL via AL1_CTRL (offset 0x10).
@   * If trigger_bool != 0: write CTRL via CTRL_TRIG (offset 0x0C) which
@     latches and starts the channel.
@
@ Stores are coalesced; the channel base lives in r12 across the four data
@ stores so we only compute it once.
@
@ Clobbers: r0-r3, r12.  Cycle count: ~14 cycles incl. push/pop.
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_configure, "ax"
    .thumb_func
    .global  dma_channel_configure
dma_channel_configure:
    @ Compute channel base into r12 (ip).  We deliberately use ip rather
    @ than r4+ so we don't have to spill any callee-saved register.
    ldr     r12, =DMA_BASE
    lsls    r0, r0, #6                     @ r0 = ch * 0x40
    add     r12, r0                        @ r12 = channel base

    @ READ_ADDR
    str     r2, [r12, #DMA_CH_READ_ADDR]
    @ WRITE_ADDR
    str     r3, [r12, #DMA_CH_WRITE_ADDR]

    @ Pop count into r2, trigger_bool into r3
    ldr     r2, [sp, #0]                   @ count
    ldr     r3, [sp, #4]                   @ trigger
    str     r2, [r12, #DMA_CH_TRANS_COUNT]

    @ Choose CTRL alias based on trigger_bool.
    cbz     r3, 1f
    @ Triggering write: CTRL_TRIG at offset 0x0C
    str     r1, [r12, #DMA_CH_CTRL_TRIG]
    bx      lr
1:  @ Non-triggering write: AL1_CTRL at offset 0x10
    str     r1, [r12, #DMA_CH_AL1_CTRL]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_start(ch) - kick a pre-configured channel via MULTI_CHAN_TRIGGER.
@   r0 = ch
@
@ MULTI_CHAN_TRIGGER is a write-1-to-trigger register: writing 1<<n triggers
@ channel n (or multiple channels at once if multiple bits are set).  We
@ write directly (not via SET alias) since the hardware ignores 0 bits.
@
@ Cycle count: 4 cycles (two ldr=4B literal loads + lsl + str).
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_start, "ax"
    .thumb_func
    .global  dma_channel_start
dma_channel_start:
    movs    r1, #1
    lsls    r1, r0
    ldr     r2, =DMA_BASE + DMA_MULTI_CHAN_TRIGGER
    str     r1, [r2]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_wait_for_finish(ch) - spin while CTRL.BUSY (bit 26) is set.
@   r0 = ch
@
@ BUSY clears when the channel finishes its last beat (or aborts).  We read
@ the canonical CTRL_TRIG register (offset 0x0C) - reads of CTRL_TRIG are
@ harmless (the trigger fires only on writes).
@
@ Inner loop is 3 cycles: ldr (2) + tst (1) + bne (1, with branch prediction).
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_wait_for_finish, "ax"
    .thumb_func
    .global  dma_channel_wait_for_finish
dma_channel_wait_for_finish:
    ldr     r1, =DMA_BASE
    lsls    r2, r0, #6
    add     r1, r2                         @ r1 = channel base
    movs    r2, #1
    lsls    r2, #DMA_CTRL_BUSY_LSB         @ r2 = 1 << 26
1:  ldr     r3, [r1, #DMA_CH_CTRL_TRIG]
    tst     r3, r2
    bne     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_abort(ch) - request abort, spin until the bit clears.
@   r0 = ch
@
@ CHAN_ABORT is W1S/RC: write 1<<n to request, the bit reads back as 1 until
@ the channel has actually halted.  Spin until cleared by hardware.
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_abort, "ax"
    .thumb_func
    .global  dma_channel_abort
dma_channel_abort:
    movs    r1, #1
    lsls    r1, r0                         @ r1 = 1 << ch
    ldr     r2, =DMA_BASE + DMA_CHAN_ABORT
    str     r1, [r2]
1:  ldr     r3, [r2]
    tst     r3, r1
    bne     1b
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_irq_enable(ch, aggregator) - INTE[a] |= 1<<ch via atomic SET.
@   r0 = ch
@   r1 = aggregator (0..3)
@
@ INTE0/1/2/3 sit at DMA_BASE + 0x404, 0x414, 0x424, 0x434 respectively.
@ Stride is 0x10.  The atomic SET alias on the DMA peripheral lets us OR
@ in our channel bit without an RMW (so no race against another core
@ touching a sibling bit).
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_irq_enable, "ax"
    .thumb_func
    .global  dma_channel_irq_enable
dma_channel_irq_enable:
    movs    r2, #1
    lsls    r2, r0                         @ r2 = 1 << ch
    @ Aggregator a -> offset 0x404 + a*0x10
    lsls    r1, r1, #4                     @ r1 = a * 0x10
    ldr     r3, =DMA_BASE + ATOMIC_SET + DMA_INTE0
    add     r3, r1                         @ INTE[a] in SET window
    str     r2, [r3]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_channel_acknowledge_irq(ch, aggregator) - W1C the channel bit in INTR.
@   r0 = ch
@   r1 = aggregator (0..3)
@
@ Per-aggregator INTR shares its W1C semantics with the legacy single-INTR
@ register; on RP2350 each aggregator's "raw status" copy mirrors INTR.
@ Writing 1<<ch to INTR clears the latched event for that channel across
@ all aggregators (by design - one edge produces one ack).
@ ----------------------------------------------------------------------------
    .section .text.dma_channel_acknowledge_irq, "ax"
    .thumb_func
    .global  dma_channel_acknowledge_irq
dma_channel_acknowledge_irq:
    movs    r2, #1
    lsls    r2, r0                         @ r2 = 1 << ch
    ldr     r3, =DMA_BASE + DMA_INTR
    str     r2, [r3]                       @ W1C
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_sniff_enable(ch, mode) - configure + enable the sniffer/CRC engine.
@   r0 = ch (0..15)
@   r1 = mode (DMA_SNIFF_CRC32 / DMA_SNIFF_CRC16 / DMA_SNIFF_SUM / ...)
@
@ Builds SNIFF_CTRL = (mode<<5) | (ch<<1) | EN, then pre-zeros SNIFF_DATA
@ so the caller can pass-through "fresh accumulator" semantics on each
@ transfer (sniffer accumulates; you must reset between runs).
@ ----------------------------------------------------------------------------
    .section .text.dma_sniff_enable, "ax"
    .thumb_func
    .global  dma_sniff_enable
dma_sniff_enable:
    @ Build SNIFF_CTRL value in r2:
    @   r2 = (mode << 5) | (ch << 1) | EN
    lsls    r1, r1, #DMA_SNIFF_CTRL_CALC_LSB    @ mode << 5
    lsls    r0, r0, #DMA_SNIFF_CTRL_DMACH_LSB   @ ch   << 1
    orrs    r1, r0
    movs    r0, #1                              @ EN
    orrs    r1, r0

    ldr     r2, =DMA_BASE
    movs    r3, #0
    str     r3, [r2, #DMA_SNIFF_DATA]           @ clear accumulator
    str     r1, [r2, #DMA_SNIFF_CTRL]
    bx      lr

@ ----------------------------------------------------------------------------
@ dma_sniff_get_data() -> r0 - read the sniffer's running result.
@ ----------------------------------------------------------------------------
    .section .text.dma_sniff_get_data, "ax"
    .thumb_func
    .global  dma_sniff_get_data
dma_sniff_get_data:
    ldr     r0, =DMA_BASE + DMA_SNIFF_DATA
    ldr     r0, [r0]
    bx      lr
