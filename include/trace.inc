@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ trace.inc - Cortex-M33 CoreSight trace infrastructure (DWT + ITM + TPIU + ETM)
@
@ References:
@   - Armv8-M Architecture Reference Manual, D1 (Debug)
@   - ARM CoreSight ETMv4 Architecture Specification (IHI0064)
@   - RP2350 datasheet §6.7 (Debug & Trace)
@ =============================================================================

@ ---- System Control Block / Debug Exception Monitor Control --------------
    .equ SCB_DEMCR,           0xE000EDFC
    .equ DEMCR_TRCENA,        (1 << 24)     @ Global trace enable

@ ---- CoreSight lock-access magic value -----------------------------------
    .equ CS_LAR_UNLOCK,       0xC5ACCE55

@ ---- DWT (Data Watchpoint and Trace) -------------------------------------
@ Base: 0xE0001000
    .equ DWT_BASE,            0xE0001000
    .equ DWT_CTRL,            0x000
    .equ DWT_CYCCNT,          0x004
    .equ DWT_CPICNT,          0x008
    .equ DWT_EXCCNT,          0x00C
    .equ DWT_SLEEPCNT,        0x010
    .equ DWT_LSUCNT,          0x014
    .equ DWT_FOLDCNT,         0x018
    .equ DWT_PCSR,            0x01C
    .equ DWT_LAR,             0xFB0

    @ DWT.CTRL bits (subset)
    .equ DWT_CTRL_CYCCNTENA,  (1 << 0)
    .equ DWT_CTRL_POSTPRESET, (0xF << 1)
    .equ DWT_CTRL_PCSAMPLENA, (1 << 12)
    .equ DWT_CTRL_EXCTRCENA,  (1 << 16)
    .equ DWT_CTRL_CPIEVTENA,  (1 << 17)
    .equ DWT_CTRL_EXCEVTENA,  (1 << 18)
    .equ DWT_CTRL_SLEEPEVTENA,(1 << 19)
    .equ DWT_CTRL_LSUEVTENA,  (1 << 20)
    .equ DWT_CTRL_FOLDEVTENA, (1 << 21)
    .equ DWT_CTRL_CYCEVTENA,  (1 << 22)

@ ---- ITM (Instrumentation Trace Macrocell) -------------------------------
@ Base: 0xE0000000.  32 stimulus ports + control regs.
    .equ ITM_BASE,            0xE0000000
    .equ ITM_STIM0,           0x000             @ 32 * 4 bytes
    .equ ITM_TER,             0xE00             @ Trace Enable Register
    .equ ITM_TPR,             0xE40             @ Trace Privilege Register
    .equ ITM_TCR,             0xE80             @ Trace Control Register
    .equ ITM_LAR,             0xFB0

    @ ITM.TCR bits
    .equ ITM_TCR_ITMENA,      (1 << 0)
    .equ ITM_TCR_TSENA,       (1 << 1)          @ Timestamps
    .equ ITM_TCR_SYNCENA,     (1 << 2)
    .equ ITM_TCR_TXENA,       (1 << 3)          @ DWT-derived packet enable
    .equ ITM_TCR_SWOENA,      (1 << 4)          @ TPIU async enable
    .equ ITM_TCR_TRACE_BUS_ID_SHIFT, 16         @ 7 bits, [22:16]

@ ---- TPIU (Trace Port Interface Unit) ------------------------------------
@ Base: 0xE0040000
    .equ TPIU_BASE,           0xE0040000
    .equ TPIU_SSPSR,          0x000             @ Supported Sync Port Sizes
    .equ TPIU_CSPSR,          0x004             @ Current Sync Port Size
    .equ TPIU_ACPR,           0x010             @ Async Clock Prescaler (SWO baud)
    .equ TPIU_SPPR,           0x0F0             @ Selected Pin Protocol
    .equ TPIU_FFSR,           0x300
    .equ TPIU_FFCR,           0x304             @ Formatter & Flush Control
    .equ TPIU_LAR,            0xFB0

    @ TPIU.SPPR pin protocols
    .equ TPIU_SPPR_SYNC,      0                 @ Parallel trace port
    .equ TPIU_SPPR_SWO_MANCHESTER, 1
    .equ TPIU_SPPR_SWO_NRZ,   2                 @ UART-style SWO

    @ TPIU.FFCR bits
    .equ TPIU_FFCR_ENFCONT,   (1 << 1)          @ Enable continuous formatter
    .equ TPIU_FFCR_TRIGIN,    (1 << 8)

@ ---- ETM (Embedded Trace Macrocell, ETMv4) -------------------------------
@ Base: 0xE0041000
    .equ ETM_BASE,            0xE0041000
    .equ ETM_TRCPRGCTLR,      0x004             @ Program control (bit 0 = EN)
    .equ ETM_TRCSTATR,        0x00C             @ IDLE bit 0, PMSTABLE bit 1
    .equ ETM_TRCCONFIGR,      0x010
    .equ ETM_TRCEVENTCTL0R,   0x020
    .equ ETM_TRCEVENTCTL1R,   0x024
    .equ ETM_TRCSTALLCTLR,    0x02C
    .equ ETM_TRCSYNCPR,       0x034
    .equ ETM_TRCTRACEIDR,     0x040             @ 7-bit trace ID
    .equ ETM_TRCVICTLR,       0x080             @ ViewInst main ctrl (start/stop)
    .equ ETM_TRCOSLAR,        0x300             @ OS Lock Access (write CS_LAR_UNLOCK)
    .equ ETM_TRCLAR,          0xFB0

    .equ ETM_TRCPRGCTLR_EN,   (1 << 0)
    .equ ETM_TRCSTATR_IDLE,   (1 << 0)
    .equ ETM_TRCSTATR_PMSTABLE, (1 << 1)
    .equ ETM_TRCVICTLR_SSSTATUS, (1 << 9)       @ Start by default
    .equ ETM_TRCCONFIGR_CID,  (1 << 6)          @ Include context ID (off here)

@ ---- Standard trace IDs we'll use ----------------------------------------
@ Each trace source on the AMBA Trace Bus needs a unique 7-bit ID.
    .equ TRACE_ID_ITM,        1
    .equ TRACE_ID_ETM,        2
