@ =============================================================================
@ pwm.inc - RP2350 PWM register map (M3-D)
@
@ Datasheet ref: RP2350 sec 12.5.  All offsets / bit positions cross-checked
@ against the Aug-2024 rev 0.3 datasheet.
@
@ The RP2350 PWM has 12 slices (the RP2040 had 8); each slice is a 16-bit
@ free-running counter with an 8.4-bit fractional clock divider, two compare
@ values (CC.A in low half, CC.B in high half), and a TOP wrap value.  Each
@ slice exposes channels A and B - 24 PWM-capable outputs in total.
@
@ Per-slice block layout (stride 0x14, 12 slices):
@   +0x00  CSR        bit fields below
@   +0x04  DIV        8.4 fixed-point divider (int << 4 | frac)
@   +0x08  CTR        current 16-bit counter value
@   +0x0C  CC         channel A in low 16, channel B in high 16
@   +0x10  TOP        16-bit wrap point
@
@ Global registers (PWM_BASE + 0xF0+):
@   0xF0  EN          one bit per slice; atomic alternative to per-slice
@                     CSR.EN that lets you start multiple slices in lock-step
@   0xF4  INTR        write 1 to clear pending wrap IRQ
@   0xF8  INTE        per-core 0 enable mask (CPU0); IRQ line PWM_IRQ_WRAP_0
@   0xFC  INTF        force-IRQ shadow
@   0x100 INTS        post-mask IRQ status (RO)
@
@ Atomic register aliases (RP2350 standard):
@   +0x0000  RW
@   +0x1000  XOR on write
@   +0x2000  SET on write
@   +0x3000  CLR on write
@ =============================================================================

@ ----- Base + slice geometry --------------------------------------------------
    .equ PWM_BASE,              0x400a8000
    .equ PWM_NUM_SLICES,        12
    .equ PWM_SLICE_STRIDE,      0x14

@ ----- Per-slice register offsets (relative to slice base) -------------------
    .equ PWM_CH_CSR,            0x00
    .equ PWM_CH_DIV,            0x04
    .equ PWM_CH_CTR,            0x08
    .equ PWM_CH_CC,             0x0C
    .equ PWM_CH_TOP,            0x10

@ ----- Global PWM registers (relative to PWM_BASE) ---------------------------
    .equ PWM_EN,                0xF0
    .equ PWM_INTR,              0xF4
    .equ PWM_INTE,              0xF8
    .equ PWM_INTF,              0xFC
    .equ PWM_INTS,              0x100

@ ----- CSR bit positions ------------------------------------------------------
@   [0]   EN          enable this slice
@   [1]   PH_CORRECT  phase-correct (up-down) mode
@   [2]   A_INV       invert channel A output
@   [3]   B_INV       invert channel B output
@   [5:4] DIVMODE     0=FREE_RUNNING, 1=GATED_B_HIGH, 2=EDGE_RISING_B,
@                     3=EDGE_FALLING_B
@   [6]   PH_RET      one-shot retard counter (write 1 to fire)
@   [7]   PH_ADV      one-shot advance counter (write 1 to fire)
    .equ PWM_CSR_EN_LSB,        0
    .equ PWM_CSR_PH_CORRECT_LSB,1
    .equ PWM_CSR_A_INV_LSB,     2
    .equ PWM_CSR_B_INV_LSB,     3
    .equ PWM_CSR_DIVMODE_LSB,   4
    .equ PWM_CSR_PH_RET_LSB,    6
    .equ PWM_CSR_PH_ADV_LSB,    7

    .equ PWM_CSR_EN,            (1 << 0)
    .equ PWM_CSR_PH_CORRECT,    (1 << 1)
    .equ PWM_CSR_A_INV,         (1 << 2)
    .equ PWM_CSR_B_INV,         (1 << 3)
    .equ PWM_CSR_DIVMODE_MASK,  (3 << 4)
    .equ PWM_CSR_PH_RET,        (1 << 6)
    .equ PWM_CSR_PH_ADV,        (1 << 7)

@ ----- DIVMODE values (bits [5:4] of CSR) ------------------------------------
    .equ PWM_DIVMODE_FREE_RUNNING,  (0 << 4)
    .equ PWM_DIVMODE_GATED_B_HIGH,  (1 << 4)
    .equ PWM_DIVMODE_EDGE_RISING_B, (2 << 4)
    .equ PWM_DIVMODE_EDGE_FALLING_B,(3 << 4)

@ ----- DIV layout: 8.4 fixed-point -------------------------------------------
@   [11:4] integer part  (1..255 effective; 0 is treated as 256 by HW)
@   [3:0]  fractional part
    .equ PWM_DIV_INT_LSB,       4
    .equ PWM_DIV_FRAC_LSB,      0

@ ----- CC: channel A low half, channel B high half ---------------------------
@   For 16-bit half-stores (STRH):
@     CC + 0  -> channel A
@     CC + 2  -> channel B
    .equ PWM_CC_A_OFFS,         0
    .equ PWM_CC_B_OFFS,         2

@ ----- RESETS bit position (datasheet sec 7.5) -------------------------------
@   PWM is bit 16 of RESETS_RESET.
    .equ RESETS_pwm,            16

@ ----- GPIO function select for PWM ------------------------------------------
@   IO_BANK0 GPIO[n].CTRL.FUNCSEL = 4 routes that pin to its PWM slice/channel.
    .equ GPIO_FUNC_PWM,         4

@ ----- NVIC IRQ line numbers --------------------------------------------------
@   RP2350 splits PWM wrap IRQs across two lines: IRQ8 covers slices 0..3
@   (legacy compat), IRQ9 covers slices 4..11.  We use the wrap_0 line that
@   covers all 12 slices in M3-D.  Datasheet sec 3.2 (interrupt table).
    .equ PWM_IRQ_WRAP_0,        8
    .equ PWM_IRQ_WRAP_1,        9

@ ----- Useful constants --------------------------------------------------------
@   1 us-per-tick configuration for a 150 MHz clk_sys: int=150 frac=0
    .equ PWM_DIV_1US_AT_150MHZ, (150 << 4)

@ -----------------------------------------------------------------------------
@ Helper macros
@ -----------------------------------------------------------------------------
@
@ pwm_slice_base reg, slice_const
@   reg <- absolute base address of the given slice (constant slice only).
@
@ pwm_gpio_to_slice / pwm_gpio_to_channel are GAS expression macros usable
@ wherever a constant is required.  RP2350 mapping (SDK macro):
@   slice = ((pin >> 1) & 7) | ((pin >> 4) & 8)
@   chan  = pin & 1   (A=0, B=1)
@ For pins 0..23 this reduces to slice = pin >> 1; for pins 24..47 the high
@ bit folds back into the slice number, so e.g. GP25 -> slice 4 ch B.
@ -----------------------------------------------------------------------------

    .macro pwm_slice_base reg, slice
        ldr     \reg, =PWM_BASE + (\slice * PWM_SLICE_STRIDE)
    .endm

    @ Constant-only mapping helpers (use as immediates).
    .equ _pwm_pin_unused, 0     @ placate gas - real expressions inline below

@ Use these as expressions:  e.g.  movs r0, #pwm_gpio_to_slice(15)
@ Note GAS macros that emit constants must be wrapped in parentheses by the
@ caller; we provide raw .equ-style helpers here as named constants for the
@ pins we actually use in examples.

    .equ PWM_SLICE_FOR_GP15,    (((15 >> 1) & 7) | ((15 >> 4) & 8))   @ = 7
    .equ PWM_CHAN_FOR_GP15,     (15 & 1)                              @ = 1 (B)
    .equ PWM_SLICE_FOR_GP25,    (((25 >> 1) & 7) | ((25 >> 4) & 8))   @ = 4
    .equ PWM_CHAN_FOR_GP25,     (25 & 1)                              @ = 1 (B)
    .equ PWM_SLICE_FOR_GP0,     (((0  >> 1) & 7) | ((0  >> 4) & 8))   @ = 0
    .equ PWM_CHAN_FOR_GP0,      (0 & 1)                               @ = 0 (A)
