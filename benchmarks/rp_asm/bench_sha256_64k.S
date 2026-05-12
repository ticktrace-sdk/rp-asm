@ =============================================================================
@ bench_sha256_64k.S — hash 64 KiB of .rodata via the hardware SHA-256 engine.
@
@ Workload: sha256_compute over a 65536-byte aligned buffer of repeating
@ 0xA5 bytes.  Report DWT cycles.  At 150 MHz the engine consumes one
@ 64-byte block per ~64 cycles, so peak ~1 ms for 64 KiB; the actual
@ number includes the CPU push loop overhead.
@
@ The source buffer is 64 KiB so the .text+.rodata of this bench is
@ correspondingly large.  That's fine — SRAM is 512 KiB.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ MSG_LEN, 65536

    .section .rodata.payload, "a"
    .align 2
payload:
    .rept 65536
    .byte 0xA5
    .endr

    .section .rodata.bench_str, "a"
name_str:     .asciz "sha256_64k"
metric_total: .asciz "cycles_total"
metric_mbps_x100: .asciz "mbps_x100"
banner:       .asciz "bench: sha256 64 KiB\r\n"

    .section .bss.bench, "aw", %nobits
    .align 2
digest:
    .space 32

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    bl      bench_standard_init
    bl      sha256_init

    ldr     r0, =banner
    bl      uart0_puts

    bl      dwt_cycles_reset
    bl      dwt_cycles_read
    mov     r4, r0

    ldr     r0, =payload
    ldr     r1, =MSG_LEN
    ldr     r2, =digest
    bl      sha256_compute

    mov     r0, r4
    bl      dwt_cycles_since
    mov     r6, r0

    ldr     r0, =name_str
    ldr     r1, =metric_total
    mov     r2, r6
    bl      bench_emit

    @ Approx MB/s × 100 = (65536 * 100 * 150) / (cycles * 1e6 / 150e6) ...
    @ Simplify: MB/s × 100 = (bytes × clk_mhz × 100) / cycles
    @   = (65536 × 150 × 100) / cycles
    @   = 983040000 / cycles
    @ Use UDIV.
    ldr     r0, =983040000
    udiv    r2, r0, r6
    ldr     r0, =name_str
    ldr     r1, =metric_mbps_x100
    bl      bench_emit

.Lhalt:
    bl      gpio_led_toggle
    ldr     r0, =12500000
1:  subs    r0, #1
    bne     1b
    b       .Lhalt
