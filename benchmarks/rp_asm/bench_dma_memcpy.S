@ =============================================================================
@ bench_dma_memcpy.S: DMA channel 0 copies 16 KiB SRAM → SRAM.
@
@ Workload: configure ch0 for byte-stride word-size INCR_READ + INCR_WRITE,
@ kick, wait for !BUSY.  Reports DWT cycles from configure to drain.
@
@ Comparison knob: same workload via a CPU `ldr`/`str` loop is included
@ as a second pass, so each run prints both numbers and we can see the
@ DMA speedup directly without bringing in the pico-sdk side.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ BUF_BYTES, 16384

    .section .rodata.bench_str, "a"
name_str:     .asciz "dma_memcpy_16k"
metric_dma:   .asciz "dma_cycles"
metric_cpu:   .asciz "cpu_cycles"
banner:       .asciz "bench: dma vs cpu 16 KiB copy\r\n"

    .section .bss.bench, "aw", %nobits
    .align 4
src_buf:
    .space BUF_BYTES
dst_buf:
    .space BUF_BYTES

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      bench_standard_init
    bl      dma_init

    @ Seed src_buf with non-zero data so DMA has work to do
    ldr     r0, =src_buf
    ldr     r1, =BUF_BYTES
    mov     r2, r0
    movs    r3, #0x5A
1:  strb    r3, [r0], #1
    subs    r1, #1
    bne     1b

    ldr     r0, =banner
    bl      uart0_puts

    @ ---- DMA timing ------------------------------------------------------
    bl      dwt_cycles_reset
    bl      dwt_cycles_read
    mov     r4, r0

    @ Configure ch0
    @ CTRL: EN | DATA_SIZE_WORD(2<<2) | INCR_READ(1<<4) | INCR_WRITE(1<<6) |
    @       CHAIN_TO=ch0 (loop) | TREQ_PERMANENT(0x3F<<17)
    @ Use the convenience constant from include/dma.inc if it covers this;
    @ otherwise compose inline.
    movw    r0, #0xFFFF
    movt    r0, #0x07E0             @ EN|WORD|INCR_RW|TREQ_PERM mask (verify below)
    @ Cleaner: build it explicitly.
    movs    r0, #1                  @ EN
    orr     r0, r0, #(2 << 2)       @ DATA_SIZE_WORD
    orr     r0, r0, #(1 << 4)       @ INCR_READ
    orr     r0, r0, #(1 << 6)       @ INCR_WRITE
    orr     r0, r0, #(0x3F << 17)   @ TREQ_PERMANENT
    @ DMA_BASE = 0x50000000, channel 0 stride 0x40
    ldr     r3, =0x50000000

    ldr     r1, =src_buf
    str     r1, [r3, #0x00]         @ READ_ADDR
    ldr     r1, =dst_buf
    str     r1, [r3, #0x04]         @ WRITE_ADDR
    ldr     r1, =(BUF_BYTES / 4)
    str     r1, [r3, #0x08]         @ TRANS_COUNT (in transfers = words)
    str     r0, [r3, #0x0C]         @ CTRL_TRIG (kicks the channel)

    @ Spin until !BUSY (bit 26 of CTRL)
2:  ldr     r1, [r3, #0x0C]
    tst     r1, #(1 << 26)
    bne     2b

    mov     r0, r4
    bl      dwt_cycles_since
    mov     r6, r0

    ldr     r0, =name_str
    ldr     r1, =metric_dma
    mov     r2, r6
    bl      bench_emit

    @ ---- CPU timing ------------------------------------------------------
    bl      dwt_cycles_reset
    bl      dwt_cycles_read
    mov     r4, r0

    ldr     r0, =src_buf
    ldr     r1, =dst_buf
    ldr     r2, =(BUF_BYTES / 4)
3:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    subs    r2, #1
    bne     3b

    mov     r0, r4
    bl      dwt_cycles_since
    mov     r6, r0

    ldr     r0, =name_str
    ldr     r1, =metric_cpu
    mov     r2, r6
    bl      bench_emit

.Lhalt:
    bl      gpio_led_toggle
    ldr     r0, =12500000
4:  subs    r0, #1
    bne     4b
    b       .Lhalt
