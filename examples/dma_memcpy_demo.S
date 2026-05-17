@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ examples/dma_memcpy_demo.S - DMA memory-to-memory throughput demo (M3-C).
@
@ Copies a 1 KiB block of constant data from .rodata into a 1 KiB region of
@ uninitialised SRAM via DMA channel 0, then copies the same block again
@ with a tight CPU loop and reports the cycle counts of both via UART.
@
@ Build:    make examples/dma_memcpy_demo.uf2  ->  build/dma_memcpy_demo.uf2
@ Verify:   115200 8N1 on GP0; expect a banner of the form
@             DMA OK  cyc=NNN
@             CPU     cyc=MMM
@           with NNN < MMM (DMA is ~one-cycle-per-word once it's saturated;
@           the CPU loop runs ~3 cycles per word in the inner ldr/str pair).
@
@ Cycle counter:
@   We use the ARMv8-M DWT.CYCCNT register (PPB at 0xE0001004) for both
@   measurements.  Enabling DEMCR.TRCENA (bit 24 of 0xE000EDFC) gates
@   DWT power; CYCCNT auto-counts once we set DWT_CTRL.CYCCNTENA (bit 0).
@   This avoids stepping on agent B's TIMER work (we touch only PPB regs
@   that are core-local and unrelated to TIMER/SysTick).
@ =============================================================================

    .include "rp2350.inc"
    .include "dma.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ---- Sizes -----------------------------------------------------------------
    .equ COPY_BYTES,     1024
    .equ COPY_WORDS,     (COPY_BYTES / 4)

@ ---- DWT -------------------------------------------------------------------
    .equ DEMCR,          0xE000EDFC
    .equ DEMCR_TRCENA,   (1 << 24)
    .equ DWT_CTRL,       0xE0001000
    .equ DWT_CYCCNT,     0xE0001004
    .equ DWT_CTRL_CYCCNTENA, (1 << 0)

@ ----------------------------------------------------------------------------
@ Constant source data: 1 KiB of a recognisable pattern.
@ ----------------------------------------------------------------------------
    .section .rodata.dma_src, "a"
    .align   4
    .global  dma_src
dma_src:
    .rept   COPY_WORDS
    .word   0xC001CAFE
    .endr

@ ----------------------------------------------------------------------------
@ Banner strings.
@ ----------------------------------------------------------------------------
    .section .rodata.dma_banners, "a"
banner_intro:
    .asciz "rp-asm M3-C: DMA memcpy demo\r\n"
banner_dma_ok:
    .asciz "DMA OK  cyc="
banner_cpu_ok:
    .asciz "CPU     cyc="
banner_nl:
    .asciz "\r\n"
banner_mismatch:
    .asciz "DMA MISMATCH\r\n"

@ ----------------------------------------------------------------------------
@ Destination region (uninitialised SRAM); 1 KiB, 4-byte aligned.
@ Sits in .bss so it doesn't bloat the UF2.
@ ----------------------------------------------------------------------------
    .section .bss.dma_dst, "aw", %nobits
    .align   4
    .global  dma_dst
dma_dst:
    .space   COPY_BYTES

@ ----------------------------------------------------------------------------
@ main
@ ----------------------------------------------------------------------------
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    push    {r4, r5, r6, r7, lr}

    @ ---- 1. UART (at the bootrom default ~12 MHz clk_peri) -----------------
    @ We deliberately skip the full PLL bring-up: this demo is about DMA
    @ memcpy throughput, not the clock tree.  uart0_init's IBRD/FBRD are
    @ already correct for the post-bootrom 12 MHz clk_peri.
    bl      gpio_led_init
    bl      uart0_init

    ldr     r0, =banner_intro
    bl      uart0_puts

    @ ---- 2. DMA bring-up ---------------------------------------------------
    bl      dma_init

    @ ---- 3. DWT cycle counter on ------------------------------------------
    @ DEMCR |= TRCENA
    ldr     r0, =DEMCR
    ldr     r1, [r0]
    ldr     r2, =DEMCR_TRCENA
    orrs    r1, r2
    str     r1, [r0]

    @ DWT_CTRL |= CYCCNTENA
    ldr     r0, =DWT_CTRL
    ldr     r1, [r0]
    movs    r2, #DWT_CTRL_CYCCNTENA
    orrs    r1, r2
    str     r1, [r0]

    @ ---- 4. DMA-paced 1 KiB memcpy + cycle measurement ---------------------
    @ Configure ch0: word-sized, both increments, no DREQ.
    @ Stack frame for the count + trigger args of dma_channel_configure:
    @   [sp+0] = count (= COPY_WORDS)
    @   [sp+4] = trigger (= 1)
    movs    r0, #COPY_WORDS
    movs    r1, #1
    push    {r0, r1}                      @ sp -> [count, trigger]

    @ Reset cycle counter
    ldr     r0, =DWT_CYCCNT
    movs    r1, #0
    str     r1, [r0]

    @ Configure + trigger: ch=0, ctrl=MEM2MEM_WORD, src=dma_src, dst=dma_dst
    movs    r0, #0
    ldr     r1, =DMA_CTRL_MEM2MEM_WORD
    ldr     r2, =dma_src
    ldr     r3, =dma_dst
    bl      dma_channel_configure

    @ Wait for completion
    movs    r0, #0
    bl      dma_channel_wait_for_finish

    @ Snapshot DMA cycles
    ldr     r0, =DWT_CYCCNT
    ldr     r4, [r0]                      @ r4 = DMA cycles (callee-saved)

    add     sp, sp, #8                    @ pop the count/trigger frame

    @ ---- 5. Print "DMA OK  cyc=<r4>\r\n" ----------------------------------
    ldr     r0, =banner_dma_ok
    bl      uart0_puts
    mov     r0, r4
    bl      print_decimal
    ldr     r0, =banner_nl
    bl      uart0_puts

    @ ---- 6. Re-zero the destination so the CPU pass actually copies ------
    ldr     r0, =dma_dst
    movs    r1, #0
    movs    r2, #COPY_WORDS
0:  str     r1, [r0], #4
    subs    r2, #1
    bne     0b

    @ ---- 7. CPU memcpy (tight 4-byte loop) + cycle measurement ------------
    ldr     r0, =DWT_CYCCNT
    movs    r1, #0
    str     r1, [r0]

    ldr     r0, =dma_src
    ldr     r1, =dma_dst
    movs    r2, #COPY_WORDS
1:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    subs    r2, #1
    bne     1b

    ldr     r0, =DWT_CYCCNT
    ldr     r5, [r0]                      @ r5 = CPU cycles

    @ ---- 8. Print "CPU     cyc=<r5>\r\n" ----------------------------------
    ldr     r0, =banner_cpu_ok
    bl      uart0_puts
    mov     r0, r5
    bl      print_decimal
    ldr     r0, =banner_nl
    bl      uart0_puts

    @ ---- 9. Verify destination matches source -----------------------------
    ldr     r0, =dma_src
    ldr     r1, =dma_dst
    movs    r2, #COPY_WORDS
2:  ldr     r3, [r0], #4
    ldr     r6, [r1], #4
    cmp     r3, r6
    bne     .Lmismatch
    subs    r2, #1
    bne     2b
    b       .Lhalt

.Lmismatch:
    ldr     r0, =banner_mismatch
    bl      uart0_puts

.Lhalt:
    @ Slow blink, no helper call - keeps the demo tiny.
3:  bl      gpio_led_toggle
    ldr     r0, =3000000
4:  subs    r0, #1
    bne     4b
    b       3b

@ ----------------------------------------------------------------------------
@ print_decimal(uint32_t x) - emit `x` as decimal via uart0_putc.
@ Recursive divide-by-10; clobbers r0-r3, lr.  ~12 instructions.
@ ----------------------------------------------------------------------------
    .section .text.print_decimal, "ax"
    .thumb_func
    .global  print_decimal
print_decimal:
    push    {r4, lr}
    movs    r1, #10
    udiv    r2, r0, r1                    @ r2 = x / 10
    mls     r4, r2, r1, r0                @ r4 = x % 10
    cbz     r2, 1f
    mov     r0, r2
    bl      print_decimal                 @ recurse on the high digits
1:  add     r0, r4, #'0'
    bl      uart0_putc
    pop     {r4, pc}
