@ =============================================================================
@ startup.S - Cortex-M33 vector table, IMAGE_DEF block, reset entry
@
@ Image layout (loaded by BOOTSEL into SRAM @ 0x20000000):
@   0x000  vector table       (16 entries / 64 bytes)
@   0x040  IMAGE_DEF block    (5 words / 20 bytes; required by RP2350 bootrom)
@   0x054  _reset             (entry point, also vec[1])
@   ...    rest of .text/.rodata
@
@ Bootrom flow on UF2 SRAM load:
@   1. UF2 blocks written to SRAM at their target addresses.
@   2. Bootrom scans first 4 KiB for an IMAGE_DEF whose flags match the boot
@      state (Arm, Secure, RP2350, EXE).
@   3. SP <- *(image_base + 0)
@      PC <- *(image_base + 4)
@   So vec[0] must be top of stack, vec[1] the reset handler.
@ =============================================================================

    .include "rp2350.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ Vector table
@ ----------------------------------------------------------------------------
    .section .vectors, "ax"
    .align   2
    .global  _vectors
_vectors:
    .word _stack_top            @  0  Initial SP
    .word _reset + 1            @  1  Reset (Thumb bit set)
    .word _halt  + 1            @  2  NMI
    .word _halt  + 1            @  3  HardFault
    .word _halt  + 1            @  4  MemManage
    .word _halt  + 1            @  5  BusFault
    .word _halt  + 1            @  6  UsageFault
    .word _halt  + 1            @  7  SecureFault
    .word 0                     @  8  reserved
    .word 0                     @  9  reserved
    .word 0                     @ 10  reserved
    .word _halt  + 1            @ 11  SVCall
    .word _halt  + 1            @ 12  DebugMon
    .word 0                     @ 13  reserved
    .word _halt  + 1            @ 14  PendSV
    .word _halt  + 1            @ 15  SysTick
    @ External IRQs 0..51 (RP2350 datasheet sec 3.2).  Default-handler =
    @ _halt so a stray IRQ parks the core instead of executing garbage.
    @ Callers wire real handlers via nvic_install_handler.
    .rept 52
    .word _halt + 1
    .endr

@ ----------------------------------------------------------------------------
@ IMAGE_DEF block (picobin format).
@
@ Flags (16-bit) for the IMAGE_TYPE item:
@   [3:0]   image_type = 1   (EXE)
@   [7:4]   security   = 2   (Secure)
@   [11:8]  cpu        = 0   (Arm)
@   [15:12] chip       = 1   (RP2350)
@ => 0x1021
@
@ If the bootrom rejects this image, the most likely culprit is the security
@ nibble: try 0x1001 (security = unspecified) or 0x1011 (NS).
@ ----------------------------------------------------------------------------
    .equ IMG_FLAGS, 0x1021

    .section .image_def, "a"
    .align   2
    .global  _image_def
_image_def:
    .word 0xffffded3                                @ PICOBIN_BLOCK_MARKER_START
    .word 0x42 | (1 << 8) | (IMG_FLAGS << 16)       @ IMAGE_TYPE item, 1 word
    .word 0xff | (1 << 8)                           @ LAST_ITEM, 1 word
    .word 0                                         @ next_block_offset = 0 (loop)
    .word 0xab123579                                @ PICOBIN_BLOCK_MARKER_END

@ ----------------------------------------------------------------------------
@ Reset handler
@ Bootrom has already set SP/PC from the vector table. We:
@   1. Point VTOR at our table (bootrom may have left it elsewhere).
@   2. Bring io_bank0 / pads_bank0 / uart0 out of reset in one shot.
@   3. Hand off to main.
@
@ Every memory write below is a single 2-cycle STR to an atomic alias - no
@ read-modify-write, no scratch on the stack.
@ ----------------------------------------------------------------------------
    .section .text._reset, "ax"
    .thumb_func
    .align   2
    .global  _reset
_reset:
    @ ---- RP2350 NO_FLASH bring-up (mirrors pico-sdk crt0.S _entry_point) ----
    @ The bootrom hands off to an SRAM image without setting MSPLIM and may
    @ not have initialised the RCP (coproc 7).  Without these three writes
    @ the first stack push or any RCP-protected bootrom path will fault.
    @
    @ 1. Enable CP7 (RCP) full access in CPACR.
    ldr     r0, =0xE000ED88                 @ CPACR
    movs    r1, #0xC0
    lsls    r1, r1, #8                      @ r1 = 0xC000 (CP7 bits = 11)
    str     r1, [r0]

    @ 2. Initialise RCP canary seeds if not already (mrc p7,#1 reports BMI
    @    when already seeded; double-init is itself a fault).
    mrc     p7, #1, APSR_nzcv, c0, c0, #0
    bmi     1f
    mcrr    p7, #8, r0, r0, c0
    mcrr    p7, #8, r0, r0, c1
    sev
1:

    @ 3. Zero MSPLIM (bootrom / debugger may have left it high).
    movs    r0, #0
    msr     msplim, r0

    @ Copy the 68-entry vector table from its load image into SRAM so that
    @ nvic_install_handler() can patch entries at runtime.  Flash-resident
    @ images have read-only vectors at 0x10000000; SRAM-resident images
    @ technically don't need this, but doing it unconditionally keeps both
    @ paths identical (and VTOR is then always at a well-known SRAM address).
    ldr     r0, =_vectors
    ldr     r1, =_ram_vectors
    movs    r2, #68                         @ words: 16 core + 52 external
2:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    subs    r2, #1
    bne     2b

    @ VTOR <- _ram_vectors
    ldr     r0, =SCB_VTOR
    ldr     r1, =_ram_vectors
    str     r1, [r0]

    @ Copy .ramfunc from its load address (in flash for flash-resident
    @ builds; same address for sram-resident) into its VMA in SRAM.  The
    @ linker emits __ramfunc_load__ / start / end so this works for both
    @ link variants.  Empty .ramfunc section -> the loop exits immediately.
    ldr     r0, =__ramfunc_load__
    ldr     r1, =__ramfunc_start__
    ldr     r2, =__ramfunc_end__
3:  cmp     r1, r2
    bge     4f
    ldr     r3, [r0], #4
    str     r3, [r1], #4
    b       3b
4:

    @ Mask of peripherals we want out of reset.  GPIO + pads only - uart0
    @ is released by uart_init (so callers that don't use UART don't wait
    @ for its RESET_DONE, which on real silicon may not assert until
    @ clk_peri is up).
    movs    r2, #1
    lsls    r3, r2, #RESETS_io_bank0
    lsls    r4, r2, #RESETS_pads_bank0
    orrs    r3, r4                  @ r3 = (1<<6)|(1<<9)

    @ Clear those bits in RESETS_RESET via the atomic CLR alias
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r3, [r0]

    @ Spin until all requested blocks report RESET_DONE
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r1, [r0]
    ands    r1, r3
    cmp     r1, r3
    bne     1b

    b       main

@ ----------------------------------------------------------------------------
@ _halt - parking spot for unimplemented vectors. WFI keeps the core cold.
@ ----------------------------------------------------------------------------
    .thumb_func
    .global  _halt
_halt:
    wfi
    b       _halt

@ ----------------------------------------------------------------------------
@ _ram_vectors - SRAM copy of the vector table, populated by _reset.
@
@ Cortex-M33 VTOR.TBLOFF[31:7] requires the vector table to be aligned to a
@ power-of-2 boundary >= the table size.  68 entries * 4 bytes = 272 bytes;
@ the smallest power of 2 >= 272 is 512, so we align to 512 bytes here.
@ ----------------------------------------------------------------------------
    .section .bss._ram_vectors, "aw", %nobits
    .align   9                       @ 2^9 = 512-byte alignment for VTOR
    .global  _ram_vectors
_ram_vectors:
    .space   68 * 4                  @ 68 * 4 = 272 bytes
