@ =============================================================================
@ tsbl_ab.S - A/B TSBL flavor with watchdog-scratch rollback tracking.
@
@ Validates both app slots, picks one based on sequence number and rollback
@ state, marks the in-flight attempt via WATCHDOG_SCRATCH[6], and hands off.
@ No flash writes - persistent promotion (STAGED -> GOOD) is the app's job
@ via boot_confirm() (see src/boot_api.S).
@
@ Selection rules (consult tsbl_ab_select for the canonical implementation):
@
@   scratch[6] = TRY_A:   previous attempt of slot A never confirmed -> B
@                          (or halt if B is invalid)
@   scratch[6] = TRY_B:   previous attempt of slot B never confirmed -> A
@                          (or halt if A is invalid)
@   scratch[6] = 0:       cold-boot or last attempt confirmed:
@                          both valid: pick higher seq (ties go to A)
@                          one valid:  pick it
@                          neither:    halt
@
@ The selector is exposed as `tsbl_ab_select` and unit-tested under T1.
@ =============================================================================

    .include "rp2350.inc"
    .include "clocks.inc"
    .include "bootloader.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ TSBL_AB_SCRATCH6, WATCHDOG_BASE + WATCHDOG_SCRATCH0 + (BL_SCRATCH_AB_REG * 4)

@ ----------------------------------------------------------------------------
@ Vector table at 0x10001000.
@ ----------------------------------------------------------------------------
    .section .tsbl_vectors, "ax"
    .align   2
    .global  _tsbl_vectors
_tsbl_vectors:
    .word _stack_top
    .word _tsbl_reset + 1
    .word _tsbl_halt  + 1       @ NMI
    .word _tsbl_halt  + 1       @ HardFault
    .word _tsbl_halt  + 1       @ MemManage
    .word _tsbl_halt  + 1       @ BusFault
    .word _tsbl_halt  + 1       @ UsageFault
    .word _tsbl_halt  + 1       @ SecureFault
    .word 0
    .word 0
    .word 0
    .word _tsbl_halt  + 1       @ SVCall
    .word _tsbl_halt  + 1       @ DebugMon
    .word 0
    .word _tsbl_halt  + 1       @ PendSV
    .word _tsbl_halt  + 1       @ SysTick

    .equ TSBL_IMG_FLAGS, 0x1021

    .section .tsbl_image_def, "a"
    .align   2
    .global  _tsbl_image_def
_tsbl_image_def:
    .word 0xffffded3
    .word 0x42 | (1 << 8) | (TSBL_IMG_FLAGS << 16)
    .word 0xff | (1 << 8)
    .word 0
    .word 0xab123579

@ ----------------------------------------------------------------------------
@ uint32_t tsbl_validate(footer_addr, slot_base, slot_size);
@
@   r0 = footer address
@   r1 = slot base address
@   r2 = slot size in bytes (including footer)
@   returns r0 = 1 (valid: magic ok, size in bounds, CRC matches)
@                0 (invalid)
@   preserves r4-r5
@ ----------------------------------------------------------------------------
    .section .text.tsbl_validate, "ax"
    .thumb_func
    .align   2
    .global  tsbl_validate
tsbl_validate:
    push    {r4, r5, lr}

    @ Magic check
    ldr     r3, [r0, #BL_FOOTER_OFF_MAGIC]
    ldr     r4, =BL_FOOTER_MAGIC
    cmp     r3, r4
    bne     .Lvalidate_no

    @ Size bound: payload_size must be <= slot_size - footer_size
    ldr     r4, [r0, #BL_FOOTER_OFF_PAYLOAD_SZ]
    subs    r2, r2, #BL_FOOTER_SIZE
    cmp     r4, r2
    bhi     .Lvalidate_no

    @ Save expected CRC, then crc32_compute over the slot.
    ldr     r5, [r0, #BL_FOOTER_OFF_CRC32]
    mov     r0, r1                      @ buf = slot base
    mov     r1, r4                      @ len = payload_size
    bl      crc32_compute
    cmp     r0, r5
    bne     .Lvalidate_no

    movs    r0, #1
    pop     {r4, r5, pc}

.Lvalidate_no:
    movs    r0, #0
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ int32_t tsbl_ab_select(footer_a, footer_b, scratch6);
@
@   r0 = footer A pointer if valid, 0 if invalid
@   r1 = footer B pointer if valid, 0 if invalid
@   r2 = current scratch[6] value
@   returns r0 = 0  (boot slot A)
@                1  (boot slot B)
@                -1 (no valid slot; halt)
@
@ Pure function: no MMIO, no globals. Exposed so the T1 harness can drive
@ the entire selection truth table without needing real footers in flash.
@ ----------------------------------------------------------------------------
    .section .text.tsbl_ab_select, "ax"
    .thumb_func
    .align   2
    .global  tsbl_ab_select
tsbl_ab_select:
    @ Rollback: A was the last in-flight attempt -> try B if valid.
    ldr     r3, =BL_SCRATCH_AB_TRY_A
    cmp     r2, r3
    bne     .Lab_check_try_b
    cbz     r1, .Lab_return_none
    movs    r0, #1
    bx      lr

.Lab_check_try_b:
    @ Rollback: B was the last in-flight attempt -> try A if valid.
    ldr     r3, =BL_SCRATCH_AB_TRY_B
    cmp     r2, r3
    bne     .Lab_normal
    cbz     r0, .Lab_return_none
    movs    r0, #0
    bx      lr

.Lab_normal:
    @ No in-flight attempt. Pick the best valid slot.
    cbz     r0, .Lab_b_only_path        @ A invalid -> consider B alone
    cbz     r1, .Lab_return_a           @ B invalid -> A is the only option

    @ Both valid. Compare seq; ties favour A (deterministic).
    ldr     r2, [r0, #BL_FOOTER_OFF_SEQ]
    ldr     r3, [r1, #BL_FOOTER_OFF_SEQ]
    cmp     r3, r2
    bhi     .Lab_return_b

.Lab_return_a:
    movs    r0, #0
    bx      lr

.Lab_return_b:
    movs    r0, #1
    bx      lr

.Lab_b_only_path:
    cbz     r1, .Lab_return_none
    movs    r0, #1
    bx      lr

.Lab_return_none:
    movs    r0, #0
    mvns    r0, r0                      @ r0 = 0xFFFFFFFF = -1
    bx      lr

@ ----------------------------------------------------------------------------
@ _tsbl_reset - validate both slots, select, mark, hand off.
@ ----------------------------------------------------------------------------
    .section .text._tsbl_reset, "ax"
    .thumb_func
    .align   2
    .global  _tsbl_reset
_tsbl_reset:
    @ ---- Cortex-M33 prologue (idempotent re-run after the SSBL) ------------
    ldr     r0, =0xE000ED88
    movs    r1, #0xC0
    lsls    r1, r1, #8
    str     r1, [r0]

    mrc     p7, #1, APSR_nzcv, c0, c0, #0
    bmi     1f
    mcrr    p7, #8, r0, r0, c0
    mcrr    p7, #8, r0, r0, c1
    sev
1:

    movs    r0, #0
    msr     msplim, r0

    @ ---- Validate slot A ---------------------------------------------------
    ldr     r0, =BL_APP_SLOT_A_FOOTER
    ldr     r1, =BL_APP_SLOT_A_BASE
    ldr     r2, =BL_APP_SLOT_A_SIZE
    bl      tsbl_validate
    mov     r4, r0                      @ r4 = a_ok (1 or 0)

    @ ---- Validate slot B ---------------------------------------------------
    ldr     r0, =BL_APP_SLOT_B_FOOTER
    ldr     r1, =BL_APP_SLOT_B_BASE
    ldr     r2, =BL_APP_SLOT_B_SIZE
    bl      tsbl_validate
    mov     r5, r0                      @ r5 = b_ok

    @ ---- Build selector inputs --------------------------------------------
    @ r0 = footer A pointer if valid, else 0
    movs    r0, #0
    cbz     r4, 1f
    ldr     r0, =BL_APP_SLOT_A_FOOTER
1:
    @ r1 = footer B pointer if valid, else 0
    movs    r1, #0
    cbz     r5, 2f
    ldr     r1, =BL_APP_SLOT_B_FOOTER
2:
    @ r2 = current scratch[6]
    ldr     r3, =TSBL_AB_SCRATCH6
    ldr     r2, [r3]

    bl      tsbl_ab_select

    @ ---- Act on selector result -------------------------------------------
    cmn     r0, #1                      @ r0 == -1 (0xFFFFFFFF)?
    beq     _tsbl_halt

    @ Stash the result; we'll need it again after writing scratch.
    mov     r4, r0

    @ Write scratch[6] = TRY_A or TRY_B before jumping. If the app doesn't
    @ call boot_confirm() (which clears scratch[6]), the next warm reset
    @ will see this marker and rollback to the other slot.
    ldr     r3, =TSBL_AB_SCRATCH6
    cbnz    r4, .Lset_try_b
    ldr     r0, =BL_SCRATCH_AB_TRY_A
    b       .Lwrite_scratch
.Lset_try_b:
    ldr     r0, =BL_SCRATCH_AB_TRY_B
.Lwrite_scratch:
    str     r0, [r3]

    @ Hand off.
    cbnz    r4, .Lhandoff_b
    ldr     r0, =BL_APP_SLOT_A_BASE
    b       .Lhandoff
.Lhandoff_b:
    ldr     r0, =BL_APP_SLOT_B_BASE
.Lhandoff:
    ldr     r1, =SCB_VTOR
    str     r0, [r1]
    ldr     r1, [r0, #0]                @ stack top
    ldr     r2, [r0, #4]                @ entry (Thumb-bit set)
    msr     msp, r1
    bx      r2

@ ----------------------------------------------------------------------------
@ _tsbl_halt - park on selection failure.
@ ----------------------------------------------------------------------------
    .section .text._tsbl_halt, "ax"
    .thumb_func
    .align   2
    .global  _tsbl_halt
_tsbl_halt:
    wfi
    b       _tsbl_halt
