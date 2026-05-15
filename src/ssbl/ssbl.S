@ =============================================================================
@ ssbl.S - rp-asm Second-Stage Bootloader.
@
@ Owns the FSBL handoff (mask-ROM bootrom -> SSBL via IMAGE_DEF / UF2) and
@ validates the next stage (TSBL) before transferring control. Target: <4 KiB
@ of flash; this build is well under that.
@
@ Responsibilities (strictly only these - anything that needs interrupts,
@ clk_peri, or USB belongs in the TSBL):
@
@   1. Cortex-M33 prologue: CPACR (CP7 enable), RCP canary seeding (idempotent
@      via the BMI check), MSPLIM = 0. Mirrors src/startup.S _reset.
@   2. Read the TSBL footer at BL_TSBL_FOOTER (= 0x10006F00).
@   3. Confirm magic == "RPBL".
@   4. Compute CRC32-IEEE over [BL_TSBL_BASE, BL_TSBL_BASE + payload_size).
@   5. Compare to the CRC32 word in the footer.
@   6. On match: VTOR <- BL_TSBL_BASE; MSP <- *(TSBL_BASE); jump *(TSBL_BASE+4).
@   7. On any failure: park in _ssbl_halt (a wfi loop).
@
@ Bootsel recovery on validation failure is deferred to Phase 2 - the SSBL
@ would write BL_SCRATCH_FORCE_BOOTSEL into WATCHDOG_SCRATCH[7] and trigger a
@ watchdog reset, kicking the chip back to mask-ROM BOOTSEL.
@ =============================================================================

    .include "rp2350.inc"
    .include "bootloader.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ Vector table at 0x10000000.
@
@ The FSBL reads vec[0] (stack) and vec[1] (reset entry) and hands off. We
@ ship only the 16 core vectors plus a NMI/HardFault/etc landing pad; the
@ SSBL never enables NVIC so no external IRQ slots are needed.
@ ----------------------------------------------------------------------------
    .section .ssbl_vectors, "ax"
    .align   2
    .global  _ssbl_vectors
_ssbl_vectors:
    .word _stack_top            @  0  Initial SP
    .word _ssbl_reset + 1       @  1  Reset (Thumb bit)
    .word _ssbl_halt  + 1       @  2  NMI
    .word _ssbl_halt  + 1       @  3  HardFault
    .word _ssbl_halt  + 1       @  4  MemManage
    .word _ssbl_halt  + 1       @  5  BusFault
    .word _ssbl_halt  + 1       @  6  UsageFault
    .word _ssbl_halt  + 1       @  7  SecureFault
    .word 0                     @  8  reserved
    .word 0                     @  9
    .word 0                     @ 10
    .word _ssbl_halt  + 1       @ 11  SVCall
    .word _ssbl_halt  + 1       @ 12  DebugMon
    .word 0                     @ 13
    .word _ssbl_halt  + 1       @ 14  PendSV
    .word _ssbl_halt  + 1       @ 15  SysTick

@ ----------------------------------------------------------------------------
@ IMAGE_DEF block at offset 0x180.
@
@ Required for the FSBL to recognise this as a valid Arm-Secure-RP2350 EXE
@ image. Format mirrors src/startup.S _image_def; flags 0x1021 = EXE | Secure
@ | Arm | RP2350.
@ ----------------------------------------------------------------------------
    .equ SSBL_IMG_FLAGS, 0x1021

    .section .ssbl_image_def, "a"
    .align   2
    .global  _ssbl_image_def
_ssbl_image_def:
    .word 0xffffded3
    .word 0x42 | (1 << 8) | (SSBL_IMG_FLAGS << 16)
    .word 0xff | (1 << 8)
    .word 0
    .word 0xab123579

@ ----------------------------------------------------------------------------
@ _ssbl_reset - the entry point. Validate TSBL, hand off.
@ ----------------------------------------------------------------------------
    .section .text._ssbl_reset, "ax"
    .thumb_func
    .align   2
    .global  _ssbl_reset
_ssbl_reset:
    @ ---- Cortex-M33 prologue (same as src/startup.S _reset) -----------------

    @ 1. CPACR <- enable CP7 (RCP) full access
    ldr     r0, =0xE000ED88                 @ CPACR
    movs    r1, #0xC0
    lsls    r1, r1, #8                      @ r1 = 0xC000 (CP7 bits = 11)
    str     r1, [r0]

    @ 2. Initialise RCP canary seeds if not already. The BMI check makes
    @    this idempotent: if the bootrom (or a debugger) already seeded
    @    them, mrc returns N=1 and we skip the mcrr writes (double-init
    @    is itself a fault).
    mrc     p7, #1, APSR_nzcv, c0, c0, #0
    bmi     1f
    mcrr    p7, #8, r0, r0, c0
    mcrr    p7, #8, r0, r0, c1
    sev
1:

    @ 3. MSPLIM <- 0
    movs    r0, #0
    msr     msplim, r0

    @ ---- Validate the TSBL footer ------------------------------------------

    @ r0 = footer base; r4 = expected magic. Footer fields are at fixed
    @ offsets from r0 (BL_FOOTER_OFF_*).
    ldr     r0, =BL_TSBL_FOOTER
    ldr     r1, [r0, #BL_FOOTER_OFF_MAGIC]
    ldr     r4, =BL_FOOTER_MAGIC
    cmp     r1, r4
    bne     _ssbl_halt

    @ Sanity-bound payload_size so a garbage footer can't make us hash
    @ all of flash. Max = slot size minus the footer itself.
    ldr     r1, [r0, #BL_FOOTER_OFF_PAYLOAD_SZ]
    ldr     r2, =(BL_TSBL_SIZE - BL_FOOTER_SIZE)
    cmp     r1, r2
    bhi     _ssbl_halt

    @ Save the expected CRC across the call to crc32_compute.
    ldr     r4, [r0, #BL_FOOTER_OFF_CRC32]

    @ ---- Compute CRC32 over TSBL payload ------------------------------------
    @ Args: r0 = buf, r1 = len. crc32_compute preserves r4.
    ldr     r0, =BL_TSBL_BASE
    bl      crc32_compute
    cmp     r0, r4
    bne     _ssbl_halt

    @ ---- Hand off to TSBL --------------------------------------------------
    @ VTOR <- TSBL_BASE; SP <- *(TSBL_BASE); PC <- *(TSBL_BASE + 4).
    ldr     r0, =BL_TSBL_BASE
    ldr     r1, =SCB_VTOR
    str     r0, [r1]

    ldr     r1, [r0, #0]                    @ TSBL stack top
    ldr     r2, [r0, #4]                    @ TSBL entry (Thumb-bit set)
    msr     msp, r1
    bx      r2

@ ----------------------------------------------------------------------------
@ _ssbl_halt - parking spot for unexpected vectors and validation failures.
@ ----------------------------------------------------------------------------
    .section .text._ssbl_halt, "ax"
    .thumb_func
    .align   2
    .global  _ssbl_halt
_ssbl_halt:
    wfi
    b       _ssbl_halt
