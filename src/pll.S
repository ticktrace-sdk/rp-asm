@ =============================================================================
@ pll.S - generic PLL bring-up + canned wrappers for sys/usb.
@
@ Datasheet ref: RP2350 sec 8.6.
@
@ Sequence (from sec 8.6.4 "Configuring the PLLs"):
@   1. Take the PLL out of reset    (RESETS_RESET CLR for pll_sys/pll_usb).
@   2. Wait for RESET_DONE.
@   3. Program FBDIV_INT (12-bit, valid 16..320).
@   4. Program REFDIV    (CS[5:0]).
@   5. Power on main + VCO          (PWR CLR PD | VCOPD).
@   6. Wait for CS.LOCK (bit 31).
@   7. Program PRIM with POSTDIV1 / POSTDIV2.
@   8. Power on the post divider    (PWR CLR POSTDIVPD).
@
@ pll_init takes the PLL base in r0 and a packed config word in r1:
@   r1[5:0]    REFDIV
@   r1[17:6]   FBDIV
@   r1[20:18]  POSTDIV1
@   r1[23:21]  POSTDIV2
@   r1[27:24]  reset bit position in RESETS_RESET (14=sys, 15=usb)
@
@ Cycle budget (without the LOCK wait):  ~30 cycles.
@ The LOCK wait dominates: ~few hundred microseconds in real silicon.
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ pll_init(base, packed_cfg)
@ Inputs : r0 = PLL_xxx_BASE
@          r1 = packed config (see header)
@ Clobbers: r0-r5.
@ ----------------------------------------------------------------------------
    .section .text.pll_init, "ax"
    .thumb_func
    .global  pll_init
pll_init:
    push    {r4, r5, lr}
    mov     r4, r0                  @ r4 = PLL base (preserved)
    mov     r5, r1                  @ r5 = packed cfg (preserved)

    @ ---- 1. Pull PLL out of reset via RESETS atomic CLR --------------------
    mov     r2, r5
    lsrs    r2, r2, #24             @ r2 = reset bit position
    movs    r3, #1
    lsls    r3, r3, r2              @ r3 = 1 << bit
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r3, [r0]

    @ Wait for the corresponding RESET_DONE bit.  This is a 3-cycle inner
    @ loop; on real silicon RESET_DONE asserts in <50 cycles.
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r3
    cmp     r2, r3
    bne     1b

    @ ---- 2. Program FBDIV_INT ---------------------------------------------
    mov     r2, r5
    lsrs    r2, r2, #6
    movw    r3, #0xFFF              @ FBDIV is 12-bit
    ands    r2, r3
    str     r2, [r4, #PLL_FBDIV_INT]

    @ ---- 3. Program REFDIV (PLL_CS[5:0]) ----------------------------------
    @ CS is RW.  Datasheet says we may write the whole word - default LOCK
    @ is 0 anyway and BYPASS=0, so writing just REFDIV is safe.
    mov     r2, r5
    movs    r3, #0x3F
    ands    r2, r3
    str     r2, [r4, #PLL_CS]

    @ ---- 4. Power up main + VCO -------------------------------------------
    @ Default PWR after reset = 0x2D (PD | DSMPD | POSTDIVPD | VCOPD).
    @ Clear PD and VCOPD (bits 0 and 5) via the atomic CLR alias.
    movs    r2, #(PLL_PWR_PD | PLL_PWR_VCOPD)
    ldr     r0, =ATOMIC_CLR
    add     r0, r0, r4
    str     r2, [r0, #PLL_PWR]

    @ ---- 5. Wait for LOCK (CS bit 31) -------------------------------------
    @ 3-cycle inner: ldr / cmp / bpl - same shape as XOSC.
2:  ldr     r2, [r4, #PLL_CS]
    cmp     r2, #0
    bpl     2b

    @ ---- 6. Program PRIM (POSTDIV1, POSTDIV2) -----------------------------
    @ Repack r5[20:18] -> bit16, r5[23:21] -> bit12.
    mov     r2, r5
    lsrs    r2, r2, #18
    movs    r3, #7
    ands    r2, r3                  @ r2 = POSTDIV1
    lsls    r2, r2, #PLL_PRIM_POSTDIV1_LSB

    mov     r3, r5
    lsrs    r3, r3, #21
    movs    r1, #7
    ands    r3, r1                  @ r3 = POSTDIV2
    lsls    r3, r3, #PLL_PRIM_POSTDIV2_LSB

    orrs    r2, r3
    str     r2, [r4, #PLL_PRIM]

    @ ---- 7. Power up the post divider -------------------------------------
    movs    r2, #PLL_PWR_POSTDIVPD
    ldr     r0, =ATOMIC_CLR
    add     r0, r0, r4
    str     r2, [r0, #PLL_PWR]

    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ pll_sys_150_mhz - 12 MHz * 125 / 1 / 5 / 2 = 150 MHz
@ ----------------------------------------------------------------------------
    .section .text.pll_sys_150_mhz, "ax"
    .thumb_func
    .global  pll_sys_150_mhz
pll_sys_150_mhz:
    ldr     r0, =PLL_SYS_BASE
    @ packed: REFDIV=1 | FBDIV<<6=125<<6 | POSTDIV1<<18=5<<18 |
    @         POSTDIV2<<21=2<<21 | reset_bit<<24=14<<24
    ldr     r1, =(1 | (125 << 6) | (5 << 18) | (2 << 21) | (RESETS_pll_sys << 24))
    b       pll_init                @ tail-call

@ ----------------------------------------------------------------------------
@ pll_usb_48_mhz - 12 MHz * 100 / 1 / 5 / 5 = 48 MHz
@ ----------------------------------------------------------------------------
    .section .text.pll_usb_48_mhz, "ax"
    .thumb_func
    .global  pll_usb_48_mhz
pll_usb_48_mhz:
    ldr     r0, =PLL_USB_BASE
    ldr     r1, =(1 | (100 << 6) | (5 << 18) | (5 << 21) | (RESETS_pll_usb << 24))
    b       pll_init                @ tail-call
