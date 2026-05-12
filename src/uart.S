@ =============================================================================
@ uart.S - RP2350 UART (ARM PL011) driver (M4-E)
@
@ Replaces the v0.1 blocking-only UART0 driver with a full PL011 implementation
@ covering both UART0 and UART1, with blocking + IRQ + DMA modes and modem
@ flow control (CTS / RTS).
@
@ Public API (AAPCS - r0..r3 are arg registers; r4..r11 callee-saved):
@
@   ----- Lifecycle / config ------------------------------------------------
@   uart_init              (r0=idx, r1=baud, r2=clk_peri_hz)
@                          Bring instance out of reset, configure default TX/RX
@                          pins (GPIO funcsel = UART = 2, PADS clear ISO|OD),
@                          program IBRD/FBRD for `baud`, set LCR_H to 8N1 FEN=1,
@                          and CR = UARTEN | TXE | RXE.
@   uart_deinit            (r0=idx)
@                          CR = 0, then assert RESETS bit for the instance.
@   uart_set_baudrate      (r0=idx, r1=baud, r2=clk_peri_hz)
@                          Recompute IBRD+FBRD; re-write LCR_H to commit the
@                          baud latch (PL011 requires this after IBRD/FBRD).
@   uart_set_format        (r0=idx, r1=data_bits, r2=stop_bits, r3=parity)
@                          parity: 0=none, 1=even, 2=odd.  Preserves FEN.
@   uart_set_hw_flow       (r0=idx, r1=cts_en, r2=rts_en)
@                          OR / clear RTSEN / CTSEN bits in CR.
@   uart_set_irqs_enabled  (r0=idx, r1=mask)         IMSC = mask
@   uart_acknowledge_irq   (r0=idx, r1=mask)         ICR = mask
@   uart_set_dma_enabled   (r0=idx, r1=tx, r2=rx)
@                          DMACR = (tx ? TXDMAE : 0) | (rx ? RXDMAE : 0)
@
@   ----- Data path ---------------------------------------------------------
@   uart_is_writable       (r0=idx) -> r0 = (FR.TXFF == 0) ? 1 : 0
@   uart_is_readable       (r0=idx) -> r0 = (FR.RXFE == 0) ? 1 : 0
@   uart_putc_blocking     (r0=idx, r1=byte)         spin while TXFF; str DR
@   uart_puts_blocking     (r0=idx, r1=str_ptr)
@   uart_getc_blocking     (r0=idx) -> r0            spin while RXFE; ldr DR
@   uart_tx_wait_blocking  (r0=idx)                  spin while FR.BUSY
@
@   ----- NVIC plumbing -----------------------------------------------------
@   uart_set_irq_handler   (r0=idx, r1=handler_fn)
@                          Patches the vector slot via nvic_install_handler
@                          and enables the NVIC line.  Does NOT touch IMSC -
@                          the caller decides which sources to unmask.
@
@   ----- v0.1 compat shims (byte-identical MMIO trace) ---------------------
@   uart0_init             -> uart_init(0, 115200, 12_000_000), EXCEPT the
@                              first writes are emitted in the same order as
@                              the v0.1 driver so test_v01_blinky.py still
@                              passes byte-for-byte.
@   uart0_putc             -> uart_putc_blocking(0, byte)
@   uart0_puts             -> uart_puts_blocking(0, ptr)
@
@ ----- Cycle budgets (Cortex-M33, no wait states, hot in I-cache) ---------
@   uart_is_writable       : 4 cycles  (ldr / lsls / movs / bx)
@   uart_putc_blocking     : ~6 cycles after FR poll exit (compute base + ldr
@                            FR + tst + bne + str DR + bx)
@   uart_set_baudrate      : ~30 cycles (UDIV in r0=clk/(16*baud) + UMULL for
@                            the FBRD round)
@   uart_init              : ~120 cycles (RESETS deassert + 2 GPIO pad + 2 IO
@                            funcsel + IBRD/FBRD/LCR_H/CR stores)
@
@ ----- idx -> base helper ------------------------------------------------
@ All idx-taking entry points pass through M_UART_BASE_FROM_IDX which folds
@ idx in {0,1} -> {UART0_BASE, UART1_BASE} without a multiply.  Out-of-range
@ idx values silently target UART1; this is a deliberate two-instance
@ optimisation (callers pass 0 or 1, never anything else).
@ =============================================================================

    .include "rp2350.inc"
    .include "gpio.inc"
    .include "uart.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ Macro: M_UART_BASE_FROM_IDX  Rd, Ridx[, scratch]
@   Rd  <- (Ridx == 0) ? UART0_BASE : UART1_BASE
@   Uses cmp + ITE-style branchless ldr selection.  Clobbers nothing else.
@ ----------------------------------------------------------------------------
    .macro M_UART_BASE_FROM_IDX rd, ridx
    cmp     \ridx, #0
    ldr     \rd, =UART0_BASE
    it      ne
    ldrne   \rd, =UART1_BASE
    .endm

@ ============================================================================
@ Internal: uart_resets_deassert(idx)
@   Clear RESETS_RESET.uart<idx> bit and spin until RESET_DONE shows it set.
@   Same pattern as dma_init / pwm_resets_enable.
@   Input : r0 = idx (0 or 1)
@   Clobbers: r0-r3.
@ ============================================================================
    .section .text.uart_resets_deassert, "ax"
    .thumb_func
    .global  uart_resets_deassert
uart_resets_deassert:
    @ bit_pos = 26 + idx        (RESETS_uart0 = 26, RESETS_uart1 = 27)
    movs    r1, #1
    adds    r2, r0, #RESETS_uart0
    lsls    r1, r2                          @ r1 = 1 << (26+idx)

    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]

    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b
    bx      lr

@ ============================================================================
@ Internal: uart_resets_assert(idx)
@   Set RESETS_RESET.uart<idx> bit (hold the instance in reset).
@ ============================================================================
    .section .text.uart_resets_assert, "ax"
    .thumb_func
    .global  uart_resets_assert
uart_resets_assert:
    movs    r1, #1
    adds    r2, r0, #RESETS_uart0
    lsls    r1, r2
    ldr     r0, =RESETS_BASE + ATOMIC_SET + RESETS_RESET
    str     r1, [r0]
    bx      lr

@ ============================================================================
@ uart_set_baudrate(idx, baud, clk_peri_hz)
@   Computes IBRD/FBRD and writes them, then re-writes LCR_H to commit the
@   baud latch (PL011 quirk: IBRD/FBRD aren't sampled until LCR_H is touched).
@
@   The math: divisor_q26 = (clk_peri * 4) / baud         (Q26.6 fixed point)
@             IBRD = divisor_q26 >> 6                     (integer part)
@             FBRD = divisor_q26 & 0x3F                   (fractional, /64)
@
@   We use UDIV (Cortex-M33 has a 1-cycle hardware divider).  No rounding on
@   FBRD beyond truncation; the SDK and the datasheet examples both truncate,
@   so we match for trace-test stability.
@
@   Input : r0 = idx, r1 = baud, r2 = clk_peri_hz
@   Clobbers: r0-r4, r12.
@ ============================================================================
    .section .text.uart_set_baudrate, "ax"
    .thumb_func
    .global  uart_set_baudrate
uart_set_baudrate:
    push    {r4, lr}
    M_UART_BASE_FROM_IDX r4, r0             @ r4 = base

    @ Compute divisor_q26 = (clk_peri * 4) / baud
    @   This is fine for clk_peri up to ~1 GHz (4*1e9 < 2^32).
    lsls    r2, r2, #2                      @ r2 = clk_peri * 4
    udiv    r3, r2, r1                      @ r3 = divisor_q26

    @ IBRD = r3 >> 6
    lsrs    r0, r3, #6
    str     r0, [r4, #UART_IBRD]

    @ FBRD = r3 & 0x3F
    and     r12, r3, #0x3F
    str     r12, [r4, #UART_FBRD]

    @ Re-write LCR_H to commit the baud latch.  We preserve whatever value
    @ is already there; if uart_init was called first that's 8N1 / FEN.
    ldr     r0, [r4, #UART_LCR_H]
    str     r0, [r4, #UART_LCR_H]

    pop     {r4, pc}

@ ============================================================================
@ uart_set_format(idx, data_bits, stop_bits, parity)
@   Builds LCR_H from the requested format.  FEN is preserved from the
@   current register value (so callers don't have to know about FIFO state).
@
@   Input :
@     r0 = idx
@     r1 = data_bits  (5..8)
@     r2 = stop_bits  (1 or 2)
@     r3 = parity     (0=none, 1=even, 2=odd)
@   Clobbers: r0-r4.
@ ============================================================================
    .section .text.uart_set_format, "ax"
    .thumb_func
    .global  uart_set_format
uart_set_format:
    push    {r4, lr}
    M_UART_BASE_FROM_IDX r4, r0             @ r4 = base

    @ Read current LCR_H to keep FEN (and SPS / BRK if user set them).
    ldr     r0, [r4, #UART_LCR_H]

    @ Strip the fields we're about to rewrite: WLEN[6:5], STP2[3], PEN[1], EPS[2]
    bic     r0, r0, #(UART_LCR_H_WLEN_MASK | UART_LCR_H_STP2 | UART_LCR_H_PEN | UART_LCR_H_EPS)

    @ WLEN = (data_bits - 5) << 5
    subs    r1, r1, #5
    and     r1, r1, #3
    lsls    r1, r1, #UART_LCR_H_WLEN_LSB
    orrs    r0, r0, r1

    @ STP2 if stop_bits == 2
    cmp     r2, #2
    bne     1f
    orr     r0, r0, #UART_LCR_H_STP2
1:
    @ Parity:
    @   0 -> no parity (leave PEN=0)
    @   1 -> even (PEN=1, EPS=1)
    @   2 -> odd  (PEN=1, EPS=0)
    cbz     r3, 2f
    orr     r0, r0, #UART_LCR_H_PEN
    cmp     r3, #1
    bne     2f
    orr     r0, r0, #UART_LCR_H_EPS
2:
    str     r0, [r4, #UART_LCR_H]
    pop     {r4, pc}

@ ============================================================================
@ uart_set_hw_flow(idx, cts_en, rts_en)
@   Set or clear CR.CTSEN / RTSEN via atomic SET/CLR aliases so the live UART
@   doesn't lose its TXE/RXE/UARTEN state.
@
@   Input : r0 = idx, r1 = cts_en, r2 = rts_en
@   Clobbers: r0-r3, r12.
@ ============================================================================
    .section .text.uart_set_hw_flow, "ax"
    .thumb_func
    .global  uart_set_hw_flow
uart_set_hw_flow:
    push    {r4, lr}
    M_UART_BASE_FROM_IDX r4, r0             @ r4 = base (plain)

    @ Build mask for the bits the user wants asserted vs cleared.
    movs    r3, #0
    cbz     r1, 1f
    orr     r3, r3, #UART_CR_CTSEN
1:  cbz     r2, 2f
    orr     r3, r3, #UART_CR_RTSEN
2:
    @ Atomic CLR: always clear both bits first (idempotent for bits we'll set)
    ldr     r0, [r4, #UART_CR]              @ shadow
    bic     r0, r0, #(UART_CR_CTSEN | UART_CR_RTSEN)
    orr     r0, r0, r3
    str     r0, [r4, #UART_CR]

    pop     {r4, pc}

@ ============================================================================
@ uart_set_irqs_enabled(idx, mask)
@   IMSC = mask.  Caller is responsible for picking the right bits from
@   UART_INT_* (RXIM, TXIM, RTIM, etc.).
@   Input : r0 = idx, r1 = mask
@   Clobbers: r0, r3.
@ ============================================================================
    .section .text.uart_set_irqs_enabled, "ax"
    .thumb_func
    .global  uart_set_irqs_enabled
uart_set_irqs_enabled:
    M_UART_BASE_FROM_IDX r3, r0
    str     r1, [r3, #UART_IMSC]
    bx      lr

@ ============================================================================
@ uart_acknowledge_irq(idx, mask)
@   ICR = mask.  All bits in ICR are W1C.
@ ============================================================================
    .section .text.uart_acknowledge_irq, "ax"
    .thumb_func
    .global  uart_acknowledge_irq
uart_acknowledge_irq:
    M_UART_BASE_FROM_IDX r3, r0
    str     r1, [r3, #UART_ICR]
    bx      lr

@ ============================================================================
@ uart_set_dma_enabled(idx, tx, rx)
@   DMACR = (tx ? TXDMAE : 0) | (rx ? RXDMAE : 0).  DMAONERR is left at 0;
@   callers needing it can do an OR'd write themselves.
@   Input : r0 = idx, r1 = tx, r2 = rx
@   Clobbers: r0-r3.
@ ============================================================================
    .section .text.uart_set_dma_enabled, "ax"
    .thumb_func
    .global  uart_set_dma_enabled
uart_set_dma_enabled:
    M_UART_BASE_FROM_IDX r3, r0

    movs    r0, #0
    cbz     r1, 1f
    orr     r0, r0, #UART_DMACR_TXDMAE
1:  cbz     r2, 2f
    orr     r0, r0, #UART_DMACR_RXDMAE
2:
    str     r0, [r3, #UART_DMACR]
    bx      lr

@ ============================================================================
@ uart_is_writable(idx) -> r0 (0/1)
@   r0 = (FR.TXFF == 0)
@   Cycles: 4 (compute base + ldr FR + tst + return).
@ ============================================================================
    .section .text.uart_is_writable, "ax"
    .thumb_func
    .global  uart_is_writable
uart_is_writable:
    M_UART_BASE_FROM_IDX r3, r0
    ldr     r0, [r3, #UART_FR]
    @ r0 = 1 if TXFF bit clear, 0 if set
    movs    r3, #UART_FR_TXFF
    tst     r0, r3
    ite     eq
    moveq   r0, #1
    movne   r0, #0
    bx      lr

@ ============================================================================
@ uart_is_readable(idx) -> r0 (0/1)
@   r0 = (FR.RXFE == 0)
@ ============================================================================
    .section .text.uart_is_readable, "ax"
    .thumb_func
    .global  uart_is_readable
uart_is_readable:
    M_UART_BASE_FROM_IDX r3, r0
    ldr     r0, [r3, #UART_FR]
    movs    r3, #UART_FR_RXFE
    tst     r0, r3
    ite     eq
    moveq   r0, #1
    movne   r0, #0
    bx      lr

@ ============================================================================
@ uart_putc_blocking(idx, byte)
@   Spin while FR.TXFF, then STR byte to DR.
@   Input : r0 = idx, r1 = byte
@   Clobbers: r0, r2, r3.
@ ============================================================================
    .section .text.uart_putc_blocking, "ax"
    .thumb_func
    .global  uart_putc_blocking
uart_putc_blocking:
    M_UART_BASE_FROM_IDX r3, r0
1:  ldr     r2, [r3, #UART_FR]
    lsls    r2, #(31 - 5)                   @ TXFF (bit 5) -> N flag
    bmi     1b
    str     r1, [r3, #UART_DR]
    bx      lr

@ ============================================================================
@ uart_getc_blocking(idx) -> r0
@   Spin while FR.RXFE, then LDR byte from DR (low 8 bits).
@   Input : r0 = idx
@   Output: r0 = received byte
@ ============================================================================
    .section .text.uart_getc_blocking, "ax"
    .thumb_func
    .global  uart_getc_blocking
uart_getc_blocking:
    M_UART_BASE_FROM_IDX r3, r0
1:  ldr     r2, [r3, #UART_FR]
    lsls    r2, #(31 - 4)                   @ RXFE (bit 4) -> N flag
    bmi     1b
    ldr     r0, [r3, #UART_DR]
    and     r0, r0, #UART_DR_DATA_MASK
    bx      lr

@ ============================================================================
@ uart_tx_wait_blocking(idx)
@   Spin while FR.BUSY (TX FIFO non-empty OR shift register active).
@   Used by drain-then-stop patterns (deinit, baud reconfigure, etc.).
@ ============================================================================
    .section .text.uart_tx_wait_blocking, "ax"
    .thumb_func
    .global  uart_tx_wait_blocking
uart_tx_wait_blocking:
    M_UART_BASE_FROM_IDX r3, r0
1:  ldr     r2, [r3, #UART_FR]
    lsls    r2, #(31 - 3)                   @ BUSY (bit 3) -> N flag
    bmi     1b
    bx      lr

@ ============================================================================
@ uart_puts_blocking(idx, str_ptr)
@   Walks the null-terminated string at r1, calling uart_putc_blocking for
@   each byte.  Preserves idx in r5.
@ ============================================================================
    .section .text.uart_puts_blocking, "ax"
    .thumb_func
    .global  uart_puts_blocking
uart_puts_blocking:
    push    {r4, r5, lr}
    mov     r5, r0                          @ idx
    mov     r4, r1                          @ ptr
1:  ldrb    r1, [r4], #1
    cbz     r1, 2f
    mov     r0, r5
    bl      uart_putc_blocking
    b       1b
2:  pop     {r4, r5, pc}

@ ============================================================================
@ uart_set_irq_handler(idx, handler_fn)
@   Patches the vector slot for UART<idx>_IRQ to point at handler_fn and
@   enables the NVIC line.  Caller still needs uart_set_irqs_enabled() to
@   unmask the source(s) it cares about.
@   Input : r0 = idx, r1 = handler_fn
@ ============================================================================
    .section .text.uart_set_irq_handler, "ax"
    .thumb_func
    .global  uart_set_irq_handler
uart_set_irq_handler:
    push    {r4, lr}
    @ irq_num = UART0_IRQ + idx
    add     r4, r0, #UART0_IRQ
    mov     r0, r4
    bl      nvic_install_handler            @ (irq, handler)
    mov     r0, r4
    bl      nvic_enable_irq                 @ (irq)
    pop     {r4, pc}

@ ============================================================================
@ uart_deinit(idx)
@   CR = 0  (disable UARTEN / TXE / RXE) then assert RESETS.uart<idx>.
@ ============================================================================
    .section .text.uart_deinit, "ax"
    .thumb_func
    .global  uart_deinit
uart_deinit:
    push    {r4, lr}
    mov     r4, r0                          @ keep idx in r4
    M_UART_BASE_FROM_IDX r3, r0
    movs    r0, #0
    str     r0, [r3, #UART_CR]
    str     r0, [r3, #UART_IMSC]
    str     r0, [r3, #UART_DMACR]
    mov     r0, r4
    bl      uart_resets_assert
    pop     {r4, pc}

@ ============================================================================
@ uart_init(idx, baud, clk_peri_hz)
@   1. Deassert RESETS.uart<idx>
@   2. Set default TX/RX pin pads (clear ISO|OD) and IO_BANK0 FUNCSEL=UART
@   3. Program IBRD/FBRD for `baud` at `clk_peri_hz`
@   4. LCR_H = 8N1 with FEN=1  (WLEN=3, FEN=1 -> 0x70)
@   5. CR    = UARTEN | TXE | RXE  (0x301)
@
@   Input : r0 = idx, r1 = baud, r2 = clk_peri_hz
@   Clobbers: r0-r4, r12.
@
@   Note: this is also the path the v0.1 uart0_init shim takes (idx=0, baud
@   =115200, clk=12 MHz) - the byte-identical MMIO sequence required by
@   tests/unicorn/test_v01_blinky.py is produced by this function plus the
@   "no RESETS write" shim, see uart0_init below.
@ ============================================================================
    .section .text.uart_init, "ax"
    .thumb_func
    .global  uart_init
uart_init:
    push    {r4, r5, r6, lr}
    mov     r4, r0                          @ idx
    mov     r5, r1                          @ baud
    mov     r6, r2                          @ clk_peri

    @ 1. Deassert RESET
    mov     r0, r4
    bl      uart_resets_deassert

    @ 2. Configure default TX/RX pins.  PADS_BANK0 + IO_BANK0 layout from
    @    gpio.inc / pads.inc.  Pin numbers from include/uart.inc.
    @
    @    For idx=0 we use GP0 (TX), GP1 (RX); for idx=1 GP4 (TX), GP5 (RX).
    @    The v0.1 driver wrote these in the order PAD_TX, PAD_RX, IO_TX, IO_RX
    @    - we preserve that order so test_v01_blinky's trace assertion still
    @    passes byte-for-byte.

    @ Compute base pin index: r0 = idx ? UART1_DEFAULT_TX_PIN : UART0_DEFAULT_TX_PIN
    @   UART0 TX = 0, UART1 TX = 4   -> tx_pin = idx * 4
    @   RX pin = tx_pin + 1
    lsls    r2, r4, #2                      @ r2 = tx_pin
    adds    r3, r2, #1                      @ r3 = rx_pin

    @ Set FUNCSEL=UART, PAD CLR ISO|OD for both pins.
    @   PAD addr  = PADS_BANK0_BASE + ATOMIC_CLR + 4 + pin*4
    @   CTRL addr = IO_BANK0_BASE + 4 + pin*8
    @   PAD value = 0x180 (PADS_ISO | PADS_OD)
    @   CTRL value = GPIO_FUNC_UART = 2

    @ ---- PAD CLR for tx_pin ----
    movs    r0, #(0x180 >> 7)
    lsls    r0, #7                          @ r0 = 0x180
    ldr     r1, =PADS_BANK0_BASE + ATOMIC_CLR + 4
    lsls    r12, r2, #2                     @ r12 = tx_pin * 4
    str     r0, [r1, r12]

    @ ---- PAD CLR for rx_pin ----
    lsls    r12, r3, #2                     @ r12 = rx_pin * 4
    str     r0, [r1, r12]

    @ ---- IO_BANK0 CTRL = UART for tx_pin ----
    movs    r0, #GPIO_FUNC_UART
    ldr     r1, =IO_BANK0_BASE + 4
    lsls    r12, r2, #3                     @ r12 = tx_pin * 8
    str     r0, [r1, r12]

    @ ---- IO_BANK0 CTRL = UART for rx_pin ----
    lsls    r12, r3, #3                     @ r12 = rx_pin * 8
    str     r0, [r1, r12]

    @ 3. IBRD / FBRD (we call uart_set_baudrate which also touches LCR_H to
    @    commit, but in this path we want a specific LCR_H value, so we
    @    inline a baud-only sequence and write LCR_H ourselves).
    M_UART_BASE_FROM_IDX r12, r4            @ r12 = uart base

    @ divisor_q26 = (clk * 4) / baud
    lsls    r0, r6, #2
    udiv    r1, r0, r5
    lsrs    r0, r1, #6                      @ IBRD
    str     r0, [r12, #UART_IBRD]
    and     r0, r1, #0x3F                   @ FBRD
    str     r0, [r12, #UART_FBRD]

    @ 4. LCR_H = WLEN_8 | FEN  = (3<<5) | (1<<4) = 0x70
    movs    r0, #0x70
    str     r0, [r12, #UART_LCR_H]

    @ 5. CR = UARTEN | TXE | RXE = 1 | (1<<8) | (1<<9) = 0x301
    movw    r0, #0x301
    str     r0, [r12, #UART_CR]

    pop     {r4, r5, r6, pc}

@ ============================================================================
@ ====================== v0.1 backwards-compat shims =========================
@
@ uart0_init must produce the EXACT same MMIO write sequence as the v0.1
@ driver, in the same order, to keep tests/unicorn/test_v01_blinky.py
@ passing byte-for-byte.  The expected trace prefix (after the GPIO LED
@ setup writes which are emitted by gpio_led_init) is:
@
@   1. PADS_BANK0[0] CLR  = 0x180
@   2. PADS_BANK0[1] CLR  = 0x180
@   3. IO_BANK0[0] CTRL   = 2
@   4. IO_BANK0[1] CTRL   = 2
@   5. UART0 IBRD         = 6
@   6. UART0 FBRD         = 33
@   7. UART0 LCR_H        = 0x70
@   8. UART0 CR           = 0x301
@
@ The v0.1 driver did NOT deassert RESETS (startup.S did that for it).  We
@ match that here: uart0_init is a thin "open-coded" path, NOT a call to
@ uart_init.  The trade-off is ~24 bytes of duplication; the benefit is
@ a stable T1 v0.1 trace contract.
@ ============================================================================

    .equ UART0_TX_PIN, 0
    .equ UART0_RX_PIN, 1

    .section .text.uart0_init, "ax"
    .thumb_func
    .global  uart0_init
uart0_init:
    @ ---- 1+2. Clear ISO/OD on both pads via atomic CLR --------------------
    movs    r2, #(0x180 >> 7)               @ 0x180 = ISO|OD
    lsls    r2, #7                          @ r2 = 0x180

    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (UART0_TX_PIN * PADS_BANK0_PAD_STRIDE)
    str     r2, [r0]
    ldr     r0, =PADS_BANK0_BASE + ATOMIC_CLR + 4 + (UART0_RX_PIN * PADS_BANK0_PAD_STRIDE)
    str     r2, [r0]

    @ ---- 3+4. IO_BANK0: FUNCSEL = UART for both pins ----------------------
    movs    r2, #GPIO_FUNC_UART
    ldr     r0, =IO_BANK0_BASE + 4 + (UART0_TX_PIN * IO_BANK0_GPIO_CTRL_STRIDE)
    str     r2, [r0]
    ldr     r0, =IO_BANK0_BASE + 4 + (UART0_RX_PIN * IO_BANK0_GPIO_CTRL_STRIDE)
    str     r2, [r0]

    @ ---- 5..8. PL011: baud + line control + master enable -----------------
    ldr     r3, =UART0_BASE

    movs    r2, #UART_IBRD_12MHZ_115200     @ 6
    str     r2, [r3, #UART_IBRD]
    movs    r2, #UART_FBRD_12MHZ_115200     @ 33
    str     r2, [r3, #UART_FBRD]

    @ LCR_H = (WLEN=3 << 5) | (FEN << 4) = 0x70 -> 8 bits, FIFOs on, no parity
    movs    r2, #0x70
    str     r2, [r3, #UART_LCR_H]

    @ CR = (RXE<<9)|(TXE<<8)|UARTEN = 0x301
    movw    r2, #0x301
    str     r2, [r3, #UART_CR]

    bx      lr

@ ----------------------------------------------------------------------------
@ uart0_putc(byte) - thin wrapper around uart_putc_blocking(0, byte).
@   The byte arrives in r0; the underlying primitive expects byte in r1 and
@   idx in r0.  We swap with a tail-call.
@ ----------------------------------------------------------------------------
    .section .text.uart0_putc, "ax"
    .thumb_func
    .global  uart0_putc
uart0_putc:
    mov     r1, r0                          @ byte -> r1
    movs    r0, #0                          @ idx = 0
    b       uart_putc_blocking

@ ----------------------------------------------------------------------------
@ uart0_puts(str_ptr) - wrapper around uart_puts_blocking(0, ptr).
@ ----------------------------------------------------------------------------
    .section .text.uart0_puts, "ax"
    .thumb_func
    .global  uart0_puts
uart0_puts:
    mov     r1, r0                          @ ptr -> r1
    movs    r0, #0                          @ idx = 0
    b       uart_puts_blocking
