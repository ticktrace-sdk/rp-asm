@ =============================================================================
@ bench_lib.S - shared helpers used by every benchmark in benchmarks/rp_asm/
@
@ Output format:
@   BENCH name=<name> metric=<metric> value=0x<hex>\r\n
@
@ A host-side parser (see benchmarks/run.sh) greps for "BENCH " and tabulates.
@ Hex output keeps the print routine to ~60 bytes and avoids /-by-10.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .rodata.bench_lib, "a"
bench_prefix:   .asciz "BENCH name="
bench_metric:   .asciz " metric="
bench_value:    .asciz " value=0x"
bench_eol:      .asciz "\r\n"
bench_hex:      .ascii "0123456789abcdef"

@ -----------------------------------------------------------------------------
@ bench_emit(r0 = name_ptr, r1 = metric_ptr, r2 = value)
@   Prints one "BENCH …" line over UART0.  Assumes UART0 is initialised.
@ -----------------------------------------------------------------------------
    .section .text.bench_emit, "ax"
    .thumb_func
    .global  bench_emit
bench_emit:
    push    {r4, r5, r6, lr}
    mov     r4, r0                  @ name
    mov     r5, r1                  @ metric
    mov     r6, r2                  @ value

    ldr     r0, =bench_prefix
    bl      uart0_puts
    mov     r0, r4
    bl      uart0_puts
    ldr     r0, =bench_metric
    bl      uart0_puts
    mov     r0, r5
    bl      uart0_puts
    ldr     r0, =bench_value
    bl      uart0_puts

    @ Print value as 8 hex digits.
    movs    r4, #28
    ldr     r5, =bench_hex
1:  mov     r0, r6
    lsrs    r0, r4
    and     r0, #0xF
    ldrb    r0, [r5, r0]
    movs    r1, r0
    movs    r0, #0
    bl      uart_putc_blocking
    subs    r4, #4
    bge     1b

    ldr     r0, =bench_eol
    bl      uart0_puts
    pop     {r4, r5, r6, pc}

@ -----------------------------------------------------------------------------
@ bench_standard_init(): clocks + UART, the standard prelude every bench uses.
@ -----------------------------------------------------------------------------
    .section .text.bench_standard_init, "ax"
    .thumb_func
    .global  bench_standard_init
bench_standard_init:
    push    {lr}
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup
    bl      dwt_init
    pop     {pc}
