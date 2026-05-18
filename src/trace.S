@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ trace.S - CoreSight trace driver: DWT cycle counter, ITM stimulus printf,
@           TPIU SWO output, ETM instruction trace.
@
@ Use case: T4 hardware debugging on a real Pico 2.  All four blocks share
@ the same enable bit (DEMCR.TRCENA), which `trace_init` sets first.
@
@ Public API:
@   ---- DWT (no probe needed, on-chip) ------------------------------------
@   dwt_init                          DEMCR.TRCENA + DWT_CTRL.CYCCNTENA
@   dwt_cycles_read() -> r0           Returns DWT_CYCCNT
@   dwt_cycles_reset                  Writes 0 to CYCCNT
@   dwt_cycles_since(r0=start)->r0    Returns (now - start) & 0xFFFFFFFF
@
@   ---- ITM (printf-over-SWO, any SWD probe) ------------------------------
@   itm_init                          Unlock + enable ITM with all 32 ports
@   itm_putc(r0=port, r1=byte)        Blocking write to ITM_STIM[port]
@   itm_puts(r0=port, r1=str_ptr)     Null-terminated string
@   itm_putw(r0=port, r1=word)        32-bit packet (faster than 4 bytes)
@
@   ---- TPIU/SWO routing (needs probe with SWO support) -------------------
@   tpiu_init_swo(r0=clk_sys_hz, r1=swo_baud)
@                                     ACPR = (clk/baud)-1; SPPR=NRZ; FFCR=cont
@
@   ---- ETM (full instruction trace, needs trace-capable probe) -----------
@   etm_init_simple                   Trace ID=2, trace everything, enable
@   etm_disable                       Quiesce before reconfiguring
@
@   ---- Convenience -------------------------------------------------------
@   trace_init(r0=clk_sys_hz, r1=swo_baud)
@                                     One-shot bring-up: DWT + ITM + TPIU + ETM
@
@ Cycle budgets (Cortex-M33 from SRAM, no probe load):
@   dwt_cycles_read:    3 cycles   (ldr / bx)
@   itm_putc, FIFO ok:  ~8 cycles  (spin ldr / cbz / strb / bx)
@   itm_putw, FIFO ok:  ~8 cycles  (1 STR puts 4 bytes on the bus)
@   trace_init:         ~80 cycles end-to-end
@ =============================================================================

    .include "trace.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ =============================================================================
@ DWT cycle counter
@ =============================================================================

@ ---- dwt_init -------------------------------------------------------------
@ Enable the global trace gate then turn on CYCCNT.
@
@ DWT registers are protected on some ARMv8-M implementations by a
@ Lock Access Register (DWT_LAR @ +0xFB0).  On RP2350 / Cortex-M33 with
@ the standard CoreSight ROM the unlock value is 0xC5ACCE55; harmless to
@ write even on implementations that don't lock.
@ ---------------------------------------------------------------------------
    .section .text.dwt_init, "ax"
    .thumb_func
    .global  dwt_init
dwt_init:
    @ Global TRCENA
    ldr     r0, =SCB_DEMCR
    ldr     r1, [r0]
    orrs    r1, r1, #DEMCR_TRCENA
    str     r1, [r0]

    @ Unlock DWT (no-op if not locked)
    ldr     r0, =DWT_BASE
    ldr     r1, =CS_LAR_UNLOCK
    str     r1, [r0, #DWT_LAR]

    @ Reset CYCCNT, then enable
    movs    r1, #0
    str     r1, [r0, #DWT_CYCCNT]
    ldr     r1, [r0, #DWT_CTRL]
    orrs    r1, r1, #DWT_CTRL_CYCCNTENA
    str     r1, [r0, #DWT_CTRL]
    bx      lr

@ ---- dwt_cycles_read ------------------------------------------------------
@ Returns r0 = DWT_CYCCNT (free-running clk_sys cycles since dwt_init).
@ 3 cycles.
    .section .text.dwt_cycles_read, "ax"
    .thumb_func
    .global  dwt_cycles_read
dwt_cycles_read:
    ldr     r0, =DWT_BASE + DWT_CYCCNT
    ldr     r0, [r0]
    bx      lr

@ ---- dwt_cycles_reset -----------------------------------------------------
    .section .text.dwt_cycles_reset, "ax"
    .thumb_func
    .global  dwt_cycles_reset
dwt_cycles_reset:
    ldr     r0, =DWT_BASE + DWT_CYCCNT
    movs    r1, #0
    str     r1, [r0]
    bx      lr

@ ---- dwt_cycles_since(start) ---------------------------------------------
@ r0 = start_value; returns r0 = (CYCCNT - start) & 0xFFFFFFFF.
@ Works across one 32-bit wrap (~28 s @ 150 MHz) because of two's complement.
    .section .text.dwt_cycles_since, "ax"
    .thumb_func
    .global  dwt_cycles_since
dwt_cycles_since:
    ldr     r1, =DWT_BASE + DWT_CYCCNT
    ldr     r1, [r1]
    subs    r0, r1, r0
    bx      lr

@ =============================================================================
@ ITM (Instrumentation Trace Macrocell)
@ =============================================================================

@ ---- itm_init -------------------------------------------------------------
@ Unlock ITM, enable all 32 stimulus ports, configure TCR for SWO output.
@ Caller must have set DEMCR.TRCENA first (dwt_init or trace_init does this).
    .section .text.itm_init, "ax"
    .thumb_func
    .global  itm_init
itm_init:
    ldr     r3, =ITM_BASE

    @ Unlock
    ldr     r0, =CS_LAR_UNLOCK
    str     r0, [r3, #ITM_LAR]

    @ Enable all 32 stimulus ports
    movs    r0, #0
    mvns    r0, r0                            @ r0 = 0xFFFFFFFF
    str     r0, [r3, #ITM_TER]

    @ Allow unprivileged access to all ports
    str     r0, [r3, #ITM_TPR]

    @ TCR: ITMENA | SWOENA | SYNCENA | TXENA | TraceBusID=TRACE_ID_ITM
    movw    r0, #(ITM_TCR_ITMENA | ITM_TCR_SYNCENA | ITM_TCR_TXENA | ITM_TCR_SWOENA)
    movs    r1, #TRACE_ID_ITM
    lsls    r1, #ITM_TCR_TRACE_BUS_ID_SHIFT
    orrs    r0, r1
    str     r0, [r3, #ITM_TCR]
    bx      lr

@ ---- itm_putc(port, byte) -------------------------------------------------
@ r0 = port (0..31), r1 = byte.  Spins on STIM[port].FIFOREADY then stores
@ a single byte.  ~8 cycles when there's space.
    .section .text.itm_putc, "ax"
    .thumb_func
    .global  itm_putc
itm_putc:
    ldr     r3, =ITM_BASE
    lsls    r0, #2                            @ port * 4
    adds    r3, r0                            @ r3 = STIM[port]
1:  ldr     r2, [r3]
    cmp     r2, #0                            @ bit 0 clear = FIFO full
    beq     1b
    strb    r1, [r3]                          @ byte write -> 1 byte packet
    bx      lr

@ ---- itm_puts(port, str) --------------------------------------------------
@ r0 = port, r1 = pointer to null-terminated string.
    .section .text.itm_puts, "ax"
    .thumb_func
    .global  itm_puts
itm_puts:
    push    {r4, r5, lr}
    mov     r4, r0                            @ port
    mov     r5, r1                            @ string ptr
1:  ldrb    r1, [r5], #1
    cbz     r1, 2f
    mov     r0, r4
    bl      itm_putc
    b       1b
2:  pop     {r4, r5, pc}

@ ---- itm_putw(port, word) -------------------------------------------------
@ r0 = port, r1 = 32-bit value.  One STR generates one 5-byte ITM packet
@ (1 header + 4 data) - useful for timestamps / register dumps.
    .section .text.itm_putw, "ax"
    .thumb_func
    .global  itm_putw
itm_putw:
    ldr     r3, =ITM_BASE
    lsls    r0, #2
    adds    r3, r0
1:  ldr     r2, [r3]
    cmp     r2, #0
    beq     1b
    str     r1, [r3]
    bx      lr

@ =============================================================================
@ TPIU (Trace Port Interface Unit) - configure SWO output
@ =============================================================================

@ ---- tpiu_init_swo(clk_sys_hz, swo_baud) ---------------------------------
@ r0 = clk_sys frequency in Hz (usually 150_000_000 post-M2)
@ r1 = desired SWO bit rate (typical: 1_000_000 .. 6_000_000)
@
@ ACPR = (clk_sys / swo_baud) - 1.
@ At clk_sys = 150 MHz, swo_baud = 2 MHz: ACPR = 74 (exact 2 Mbps).
@ At clk_sys = 150 MHz, swo_baud = 1 MHz: ACPR = 149 (exact 1 Mbps).
    .section .text.tpiu_init_swo, "ax"
    .thumb_func
    .global  tpiu_init_swo
tpiu_init_swo:
    ldr     r3, =TPIU_BASE

    @ Unlock TPIU (CS-protected on some cores; harmless if not).
    ldr     r2, =CS_LAR_UNLOCK
    str     r2, [r3, #TPIU_LAR]

    @ SPPR = NRZ (async UART-like SWO)
    movs    r2, #TPIU_SPPR_SWO_NRZ
    str     r2, [r3, #TPIU_SPPR]

    @ ACPR = (clk / baud) - 1
    udiv    r2, r0, r1
    subs    r2, #1
    str     r2, [r3, #TPIU_ACPR]

    @ FFCR: disable formatter (we just want raw ITM/ETM bytes on SWO).
    @ For SWO we want bit 0 (EnFCont) clear and bit 1 (PMode/none) clear.
    movs    r2, #0
    str     r2, [r3, #TPIU_FFCR]

    @ CSPSR = 1 (1-bit port; only meaningful for parallel mode, harmless here)
    movs    r2, #1
    str     r2, [r3, #TPIU_CSPSR]
    bx      lr

@ =============================================================================
@ ETM (Embedded Trace Macrocell, ETMv4) - simple instruction trace
@ =============================================================================

@ ---- etm_init_simple ------------------------------------------------------
@ Configure ETM for "trace everything, single thread" output on TraceBus ID 2.
@ The probe is expected to consume the resulting trace stream off SWO/TRACE.
    .section .text.etm_init_simple, "ax"
    .thumb_func
    .global  etm_init_simple
etm_init_simple:
    ldr     r3, =ETM_BASE

    @ Unlock software/OS locks (write magic to both LAR + OSLAR).
    ldr     r0, =CS_LAR_UNLOCK
    str     r0, [r3, #ETM_TRCLAR]
    movs    r0, #0
    str     r0, [r3, #ETM_TRCOSLAR]            @ OS-unlock: write 0

    @ Disable for reprogramming
    movs    r0, #0
    str     r0, [r3, #ETM_TRCPRGCTLR]

    @ Wait for IDLE
1:  ldr     r0, [r3, #ETM_TRCSTATR]
    tst     r0, #ETM_TRCSTATR_IDLE
    beq     1b

    @ Minimal config: no return-stack, no virt-addr, no context-ID, no branch-broadcast.
    movs    r0, #0
    str     r0, [r3, #ETM_TRCCONFIGR]

    @ Trace ID
    movs    r0, #TRACE_ID_ETM
    str     r0, [r3, #ETM_TRCTRACEIDR]

    @ ViewInst: start by default (SSSTATUS=1), no stop event, no comparator pairs.
    movw    r0, #ETM_TRCVICTLR_SSSTATUS
    str     r0, [r3, #ETM_TRCVICTLR]

    @ No event triggers, no stall, sync packet every 1024 cycles
    movs    r0, #0
    str     r0, [r3, #ETM_TRCEVENTCTL0R]
    str     r0, [r3, #ETM_TRCEVENTCTL1R]
    str     r0, [r3, #ETM_TRCSTALLCTLR]
    movs    r0, #10                           @ TRCSYNCPR is log2(N); 10 => 1024
    str     r0, [r3, #ETM_TRCSYNCPR]

    @ Enable
    movs    r0, #ETM_TRCPRGCTLR_EN
    str     r0, [r3, #ETM_TRCPRGCTLR]

    @ Wait until PMSTABLE (programming committed)
2:  ldr     r0, [r3, #ETM_TRCSTATR]
    tst     r0, #ETM_TRCSTATR_PMSTABLE
    beq     2b
    bx      lr

@ ---- etm_disable ----------------------------------------------------------
    .section .text.etm_disable, "ax"
    .thumb_func
    .global  etm_disable
etm_disable:
    ldr     r3, =ETM_BASE
    movs    r0, #0
    str     r0, [r3, #ETM_TRCPRGCTLR]
1:  ldr     r0, [r3, #ETM_TRCSTATR]
    tst     r0, #ETM_TRCSTATR_IDLE
    beq     1b
    bx      lr

@ =============================================================================
@ trace_init - one-shot bring-up of every component
@ =============================================================================
@ r0 = clk_sys_hz, r1 = swo_baud
@ Order matters: DEMCR.TRCENA first (dwt_init does this), then TPIU
@ (so ITM/ETM have somewhere to emit), then ITM, then ETM.
    .section .text.trace_init, "ax"
    .thumb_func
    .global  trace_init
trace_init:
    push    {r4, r5, lr}
    mov     r4, r0
    mov     r5, r1
    bl      dwt_init                  @ also sets TRCENA
    mov     r0, r4
    mov     r1, r5
    bl      tpiu_init_swo
    bl      itm_init
    bl      etm_init_simple
    pop     {r4, r5, pc}
