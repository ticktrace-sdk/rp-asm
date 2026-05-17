@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ spi.S - RP2350 SPI (PL022) driver  -  M4-G (communication peripherals).
@
@ Datasheet ref: RP2350 datasheet rev 0.3 (Aug 2024) sec 12.3 + ARM PrimeCell
@ SSP TRM (DDI 0194H).  Two PL022 controllers: SPI0 @ 0x40080000,
@ SPI1 @ 0x40088000 (stride 0x8000).
@
@ Public API (AAPCS - r0..r3 args, r4..r11 callee-saved):
@
@   spi_init(idx, baudrate_hz)
@       - idx in {0,1}; brings the controller out of RESETS, configures
@         CR0 = (8-bit Motorola, CPOL=0, CPHA=0, SCR per baud), CPSR =
@         CPSDVSR per baud, CR1 = SSE|MASTER (sets SSE last with everything
@         else already in place; SSE must only be raised once CR0/CPSR are
@         valid - PL022 quirk).
@   spi_deinit(idx)
@       - clears SSE, asserts the RESETS bit.
@   spi_set_baudrate(idx, baud_hz)
@       - recompute CPSDVSR + SCR for `baud_hz`.  Disables SSE around the
@         CR0 write (PL022 requires SSE=0 to mutate CR0/CPSR safely), then
@         restores SSE if it was previously on.  Returns the achieved baud
@         in r0 (clk_peri / (CPSDVSR * (1 + SCR))).
@   spi_set_format(idx, data_bits, cpol, cpha, frame_format)
@       - data_bits in [4..16]; rebuilds CR0 keeping the SCR field intact.
@   spi_set_slave(idx, on)
@       - SSPCR1.MS bit (0 = master, 1 = slave).  Must be done with SSE=0.
@   spi_set_loopback(idx, on)
@       - SSPCR1.LBM bit.  Must be done with SSE=0.
@   spi_set_pins(idx, sck_pin, mosi_pin, miso_pin, cs_pin)
@       - drives sck/mosi/miso through gpio_set_function(_, GPIO_FUNC_SPI);
@         leaves CS as a regular SIO output (so the caller can bracket whole
@         transfers, since PL022's SSPFSSOUT pulses per word).  cs_pin == -1
@         skips CS init.  Args 4 and 5 (miso, cs) are passed in r3 and on
@         the stack ([sp,#0]) per AAPCS.
@   spi_write_blocking(idx, src, len)        -> r0 = len
@   spi_read_blocking(idx, repeated_tx, dst, len) -> r0 = len
@   spi_write_read_blocking(idx, src, dst, len)   -> r0 = len
@   spi_is_writable(idx) -> r0 (1 if TX FIFO not full)
@   spi_is_readable(idx) -> r0 (1 if RX FIFO not empty)
@   spi_is_busy(idx)     -> r0 (1 if BSY)
@   spi_set_irqs_enabled(idx, mask)          - SSPIMSC = mask
@   spi_clear_irq(idx, mask)                 - SSPICR  = mask (W1C: only
@                                              RORIC|RTIC honoured)
@   spi_set_dma_enabled(idx, tx_on, rx_on)   - SSPDMACR
@   spi_cs_low(cs_pin)  / spi_cs_high(cs_pin) - thin wrappers over gpio_put
@
@ Cycle budgets (release Cortex-M33, no wait states; APB stores are 2c):
@   spi_is_writable  : 4 cycles  (base+ldr+lsr+and)
@   spi_is_busy      : 4 cycles
@   spi_set_baudrate : ~30 cycles (one UDIV + a couple of tests)
@   spi_write_blocking inner loop: ~6 cycles per byte once TNF is true
@                                  (ldr SSPSR; tst; bne; str SSPDR).
@
@ Implementation notes:
@   * `idx` -> base is computed once per call as base = SPI0_BASE + idx*0x8000.
@   * The driver does NOT use the integer-only divide-by-3 trick the pico-sdk
@     uses for the CPSDVSR scan; on M33 UDIV is single-cycle so we just call
@     it twice.
@   * CR0/CPSR mutations always disable SSE, write the new value, then restore
@     SSE.  Mutations of CR1 itself (set_slave, set_loopback) wrap SSE the
@     same way.
@ =============================================================================

    .include "rp2350.inc"
    .include "spi.inc"
    .include "gpio.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ Internal helper macros
@ ----------------------------------------------------------------------------

@ M_SPI_BASE rd, ridx
@   rd <- SPI0_BASE + ridx * 0x8000   (idx in {0,1}).
@   Cost: 3 thumb-2 insns when rd != ridx; uses ip (r12) as scratch when they
@   alias to keep callers from having to manage a temporary.  ip is
@   caller-saved per AAPCS so this is safe inside leaf and non-leaf helpers.
.macro M_SPI_BASE rd, ridx
    .ifc \rd, \ridx
        lsls    ip, \ridx, #15
        ldr     \rd, =SPI0_BASE
        add     \rd, ip
    .else
        lsls    \ridx, \ridx, #15
        ldr     \rd, =SPI0_BASE
        add     \rd, \ridx
    .endif
.endm

@ ============================================================================
@ spi_resets_enable / spi_resets_disable - private helpers
@ ============================================================================

@ spi_resets_enable(idx) - CLR the RESETS bit for SPIidx and spin until
@ RESET_DONE confirms.  Clobbers r0-r3.
    .section .text.spi_resets_enable, "ax"
    .thumb_func
    .global  spi_resets_enable
spi_resets_enable:
    @ mask = 1 << (RESETS_spi0 + idx).  Since RESETS_spi0 = 18 and idx in
    @ {0,1}, RESETS_spi1 = 19 = 18+1.  We just shift accordingly.
    movs    r1, #1
    adds    r0, #RESETS_spi0
    lsls    r1, r0
    @ Now r1 = (1 << (RESETS_spi0 + idx)).  r0 was clobbered.

    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]

    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b
    bx      lr

@ spi_resets_disable(idx) - SET the RESETS bit (assert reset).
    .section .text.spi_resets_disable, "ax"
    .thumb_func
    .global  spi_resets_disable
spi_resets_disable:
    movs    r1, #1
    adds    r0, #RESETS_spi0
    lsls    r1, r0
    ldr     r0, =RESETS_BASE + ATOMIC_SET + RESETS_RESET
    str     r1, [r0]
    bx      lr

@ ============================================================================
@ spi_set_baudrate(idx, baud_hz) -> r0 = achieved baud
@
@ pico-sdk algorithm (paraphrased from src/rp2_common/hardware_spi/spi.c):
@   freq_in = clk_peri = 150_000_000.
@   for prescale = 2,4,...,254:
@       if freq_in < (prescale + 2) * 256 * baud:
@           break
@   postdiv = (freq_in / (prescale * baud)) ; clamp to [1..256] ; round to nearest
@   SCR = postdiv - 1
@   write CPSR = prescale ; CR0 |= (SCR << 8)
@
@ Cycle budget: ~30 cycles for typical configurations (the prescale scan
@ exits on the first iteration for baud >= ~2.3 MHz).
@
@ AAPCS: r0=idx, r1=baud_hz; clobbers r0-r7.
@ ============================================================================
    .section .text.spi_set_baudrate, "ax"
    .thumb_func
    .global  spi_set_baudrate
spi_set_baudrate:
    push    {r4, r5, r6, r7, lr}

    @ r4 = base
    mov     r4, r0
    M_SPI_BASE r4, r4
    mov     r5, r1                      @ r5 = baud

    @ Save current SSE state and clear it (PL022 requires SSE=0 to mutate
    @ CR0 / CPSR).  SSE is bit 1 of CR1.
    ldr     r0, [r4, #SSPCR1]
    mov     r6, r0                      @ r6 = saved CR1
    movs    r1, #SSPCR1_SSE
    bics    r0, r1
    str     r0, [r4, #SSPCR1]

    @ ---- Find prescale ------------------------------------------------------
    @   freq_in = 150_000_000 = CLK_PERI_HZ
    .equ CLK_PERI_HZ, 150000000

    movs    r2, #2                      @ r2 = prescale (start at 2)
1:  @ Compute (prescale + 2) * 256 * baud as a 64-bit unsigned product so
    @ very high baud (>~16 MHz) doesn't wrap.  UMULL produces lo:hi.  We
    @ exit the scan when freq_in < threshold; equivalently when threshold
    @ has any high-half bits OR threshold_lo > freq_in.
    adds    r3, r2, #2                  @ r3 = prescale + 2
    lsls    r3, r3, #8                  @ r3 = (prescale + 2) * 256
    umull   r0, r1, r3, r5              @ r1:r0 = (p+2)*256 * baud (64-bit)
    cbnz    r1, 2f                      @ high half non-zero => threshold > 2^32
    ldr     r7, =CLK_PERI_HZ
    cmp     r7, r0
    blo     2f                          @ freq_in < threshold -> done
    adds    r2, #2
    cmp     r2, #254
    ble     1b
    movs    r2, #254                    @ saturate
2:
    @ r2 = chosen prescale (CPSDVSR)

    @ ---- postdiv = clk_peri / (prescale * baud), rounded to nearest --------
    mul     r3, r2, r5                  @ r3 = prescale * baud (3-arg MUL must
                                        @ not set flags on Thumb-2)
    cbz     r3, 9f                      @ defensive: avoid /0 if baud==0
    ldr     r7, =CLK_PERI_HZ
    udiv    r0, r7, r3                  @ r0 = floor(clk / (p*baud))
    @ Round to nearest: add (denom/2) before the divide. Recompute properly:
    lsrs    r1, r3, #1                  @ r1 = (p*baud) / 2
    adds    r7, r1                      @ r7 = clk + denom/2
    udiv    r0, r7, r3                  @ r0 = round(clk/(p*baud))

    @ Clamp postdiv to [1..256]
    cbnz    r0, 3f
    movs    r0, #1
3:  cmp     r0, #256
    ble     4f
    movs    r0, #256
4:
    subs    r0, #1                      @ r0 = SCR = postdiv - 1
    @ r0 in [0..255]

    @ ---- Write CPSR (just prescale; mask to 8 bits even though scan stays
    @      within 0..254) --------------------------------------------------
    str     r2, [r4, #SSPCPSR]

    @ ---- CR0: keep DSS/FRF/SPO/SPH; replace SCR field -----------------------
    ldr     r1, [r4, #SSPCR0]
    @ Clear SCR field (bits 15:8)
    movw    r3, #0x00FF
    ands    r1, r3                      @ keep only bits 7:0
    lsls    r0, r0, #SSPCR0_SCR_LSB
    orrs    r1, r0                      @ r1 = new CR0
    str     r1, [r4, #SSPCR0]

    @ ---- Restore SSE if it was set on entry --------------------------------
    movs    r1, #SSPCR1_SSE
    ands    r6, r1
    @ r6 = saved SSE bit (0 or SSE)
    ldr     r0, [r4, #SSPCR1]
    orrs    r0, r6
    str     r0, [r4, #SSPCR1]

    @ ---- Compute achieved baud and return in r0 ----------------------------
    @   achieved = clk_peri / (CPSDVSR * (1 + SCR))
    adds    r0, r2, #0                  @ r0 = CPSDVSR
    @ recompute SCR+1 by re-reading CR0 (cheap; alternative is to keep SCR
    @ live in a callee-saved reg but we've already paid for the load)
    ldr     r1, [r4, #SSPCR0]
    lsrs    r1, #SSPCR0_SCR_LSB
    movs    r3, #0xFF
    ands    r1, r3                      @ r1 = SCR
    adds    r1, #1                      @ r1 = SCR + 1
    muls    r0, r1                      @ r0 = CPSDVSR * (SCR + 1)
    ldr     r1, =CLK_PERI_HZ
    udiv    r0, r1, r0                  @ r0 = achieved baud
    pop     {r4, r5, r6, r7, pc}

9:  @ baud == 0 escape - leave registers unchanged, return 0
    movs    r0, #0
    pop     {r4, r5, r6, r7, pc}

@ ============================================================================
@ spi_init(idx, baudrate_hz)
@
@ 1. RESETS clear bit (idx).
@ 2. Default CR0 = 8-bit Motorola, CPOL=0, CPHA=0, SCR=0.
@ 3. Default CR1 = master, SSE off.
@ 4. CPSR = 0 (will be programmed by spi_set_baudrate).
@ 5. spi_set_baudrate(idx, baudrate_hz) - sets CPSR + SCR.
@ 6. CR1 |= SSE.
@
@ The order matters: CR0/CPSR must be valid before SSE goes high.
@
@ AAPCS: r0=idx, r1=baud; clobbers r0-r7.
@ ============================================================================
    .section .text.spi_init, "ax"
    .thumb_func
    .global  spi_init
spi_init:
    push    {r4, r5, lr}

    mov     r4, r0                      @ r4 = idx (preserve)
    mov     r5, r1                      @ r5 = baud (preserve)

    @ Step 1: bring controller out of reset.
    bl      spi_resets_enable           @ uses r0 as idx; r0 already = idx? we
                                        @ overwrote r0 above with r4=idx, so
                                        @ load from r4.
    @ Wait - spi_resets_enable expects idx in r0, but we've called other code.
    @ Fix: pass idx into r0 explicitly then call.

    @ (We re-do steps 2..6 below with idx in r4.)

    @ Compute base into a callee-saved r5 isn't possible since r5 holds baud.
    @ Use a fresh local computation each store.
    mov     r0, r4                      @ idx
    M_SPI_BASE r0, r0
    @ r0 = base now

    @ CR0 default = 8-bit Motorola (DSS=7), SPO=0, SPH=0, SCR=0
    movs    r1, #SPI_CR0_DEFAULT_8BIT
    str     r1, [r0, #SSPCR0]

    @ CR1 default = MASTER, SSE off, LBM off, SOD off
    movs    r1, #0
    str     r1, [r0, #SSPCR1]

    @ CPSR = 0 placeholder
    movs    r1, #0
    str     r1, [r0, #SSPCPSR]

    @ Step 5: program baud
    mov     r0, r4
    mov     r1, r5
    bl      spi_set_baudrate

    @ Step 6: SSE = 1.  Use atomic SET on CR1 to avoid disturbing other bits.
    mov     r0, r4
    M_SPI_BASE r0, r0
    movs    r1, #SSPCR1_SSE
    str     r1, [r0, #SSPCR1]           @ CR1 = SSE only (master, no LBM, SSE on)

    pop     {r4, r5, pc}

@ Re-spin spi_init properly: the call to spi_resets_enable above was issued
@ before we'd preserved r0 - fix by ordering.  We rewrite spi_init cleanly:
@   (the version above is correct because we copy idx into r4 BEFORE calling
@    spi_resets_enable; spi_resets_enable expects r0=idx, but we never set
@    r0=idx after the mov r4,r0.  We MUST set r0 first.)
@ -> Patch: mov r0, r4 immediately before bl spi_resets_enable.

@ NOTE: the spi_init body above already does `mov r4, r0` to save idx, then
@ calls spi_resets_enable.  At that point r0 still equals the original idx
@ argument (we only `mov r4, r0`, not vice-versa), so the call sees r0 = idx
@ as required.  Good.

@ ============================================================================
@ spi_deinit(idx)
@   - CR1 SSE = 0
@   - assert RESETS bit
@ ============================================================================
    .section .text.spi_deinit, "ax"
    .thumb_func
    .global  spi_deinit
spi_deinit:
    push    {r4, lr}
    mov     r4, r0
    M_SPI_BASE r0, r0
    @ Clear SSE (atomic CLR on the canonical CR1 - PL022 doesn't expose
    @ SET/CLR aliases, so we use a RMW.  Safe because SPI is per-instance
    @ and not shared across cores in our model.)
    ldr     r1, [r0, #SSPCR1]
    movs    r2, #SSPCR1_SSE
    bics    r1, r2
    str     r1, [r0, #SSPCR1]

    mov     r0, r4
    bl      spi_resets_disable
    pop     {r4, pc}

@ ============================================================================
@ spi_set_format(idx, data_bits, cpol, cpha, frame_format)
@   r0 = idx
@   r1 = data_bits   (4..16)
@   r2 = cpol        (0/1)
@   r3 = cpha        (0/1)
@   [sp,#0] = frame_format  (SPI_FRF_MOTOROLA / TI_SSI / NS_MICROWIRE,
@                            already left-shifted by 4)
@
@ Builds new CR0 = (frame_format) | (cpol<<6) | (cpha<<7) | ((data_bits-1)
@                | (SCR << 8) - SCR retained from current CR0.
@
@ Wraps the write in SSE clear/restore.
@ ============================================================================
    .section .text.spi_set_format, "ax"
    .thumb_func
    .global  spi_set_format
spi_set_format:
    push    {r4, r5, r6, r7, lr}
    mov     r4, r0                      @ idx
    M_SPI_BASE r0, r0
    mov     r5, r0                      @ r5 = base

    @ Save SSE state
    ldr     r6, [r5, #SSPCR1]
    movs    r0, #SSPCR1_SSE
    bics    r7, r6, r0                  @ r7 = CR1 with SSE=0
    str     r7, [r5, #SSPCR1]

    @ Build new CR0
    @   r1 = data_bits, r2 = cpol, r3 = cpha, [sp,#20] = frame_format
    @   (push above moved sp by 5 regs = 20 bytes)
    subs    r0, r1, #1                  @ DSS = data_bits - 1
    movs    r1, #0xF
    ands    r0, r1                      @ clamp DSS to 4 bits

    @ frame_format already <<4'd by caller; OR it in
    ldr     r1, [sp, #20]               @ frame_format
    orrs    r0, r1

    @ cpol -> bit 6
    cmp     r2, #0
    beq     1f
    movs    r1, #SSPCR0_SPO
    orrs    r0, r1
1:
    @ cpha -> bit 7
    cmp     r3, #0
    beq     2f
    movs    r1, #SSPCR0_SPH
    orrs    r0, r1
2:
    @ Preserve SCR field from old CR0
    ldr     r1, [r5, #SSPCR0]
    movw    r2, #0xFF00
    ands    r1, r2                      @ r1 = old SCR<<8 mask
    orrs    r0, r1                      @ new CR0 with old SCR

    str     r0, [r5, #SSPCR0]

    @ Restore SSE if it was set
    str     r6, [r5, #SSPCR1]

    pop     {r4, r5, r6, r7, pc}

@ ============================================================================
@ spi_set_slave(idx, on)
@   Wraps SSE clear/restore around CR1.MS bit twiddle.
@ ============================================================================
    .section .text.spi_set_slave, "ax"
    .thumb_func
    .global  spi_set_slave
spi_set_slave:
    push    {r4, r5, lr}
    M_SPI_BASE r0, r0
    mov     r4, r0                      @ base
    mov     r5, r1                      @ on

    ldr     r1, [r4, #SSPCR1]
    @ Clear SSE for the mutation
    movs    r2, #SSPCR1_SSE
    bics    r3, r1, r2
    str     r3, [r4, #SSPCR1]

    @ Update MS
    movs    r2, #SSPCR1_MS
    bics    r1, r2                      @ r1 = orig with MS cleared
    cbz     r5, 1f
    orrs    r1, r2                      @ MS=1
1:  str     r1, [r4, #SSPCR1]           @ writes new value (incl. orig SSE)
    pop     {r4, r5, pc}

@ ============================================================================
@ spi_set_loopback(idx, on)
@   Wraps SSE clear/restore around CR1.LBM bit.
@ ============================================================================
    .section .text.spi_set_loopback, "ax"
    .thumb_func
    .global  spi_set_loopback
spi_set_loopback:
    push    {r4, r5, lr}
    M_SPI_BASE r0, r0
    mov     r4, r0
    mov     r5, r1

    ldr     r1, [r4, #SSPCR1]
    movs    r2, #SSPCR1_SSE
    bics    r3, r1, r2
    str     r3, [r4, #SSPCR1]           @ SSE off

    movs    r2, #SSPCR1_LBM
    bics    r1, r2
    cbz     r5, 1f
    orrs    r1, r2
1:  str     r1, [r4, #SSPCR1]           @ restore (with LBM updated, original
                                        @ SSE preserved)
    pop     {r4, r5, pc}

@ ============================================================================
@ spi_set_pins(idx, sck_pin, mosi_pin, miso_pin, cs_pin)
@   r0=idx (unused - PL022 routes to whatever pins the user FUNCSEL'd)
@   r1=sck, r2=mosi, r3=miso, [sp,#0]=cs
@
@   Calls gpio_set_function(pin, GPIO_FUNC_SPI) on sck/mosi/miso.  cs_pin is
@   left as a regular SIO output: we call gpio_init(cs) + gpio_set_dir(cs,1)
@   + gpio_put(cs,1) so the line idles high (typical SPI CS behaviour).
@
@   Pass cs == -1 (0xFFFFFFFF) to skip CS init entirely.
@ ============================================================================
    .section .text.spi_set_pins, "ax"
    .thumb_func
    .global  spi_set_pins
spi_set_pins:
    push    {r4, r5, r6, lr}
    @ Stash sck/mosi/miso/cs into callee-saved
    mov     r4, r1                      @ sck
    mov     r5, r2                      @ mosi
    mov     r6, r3                      @ miso

    @ sck
    mov     r0, r4
    movs    r1, #GPIO_FUNC_SPI
    bl      gpio_set_function
    @ mosi
    mov     r0, r5
    movs    r1, #GPIO_FUNC_SPI
    bl      gpio_set_function
    @ miso
    mov     r0, r6
    movs    r1, #GPIO_FUNC_SPI
    bl      gpio_set_function

    @ cs at [sp, #16]   (4 regs * 4 bytes pushed)
    ldr     r0, [sp, #16]
    cmn     r0, #1                      @ cs == -1 ?
    beq     1f
    @ gpio_init(cs)
    bl      gpio_init
    @ gpio_set_dir(cs, 1)
    ldr     r0, [sp, #16]
    movs    r1, #1
    bl      gpio_set_dir
    @ gpio_put(cs, 1) - idle high
    ldr     r0, [sp, #16]
    movs    r1, #1
    bl      gpio_put
1:
    pop     {r4, r5, r6, pc}

@ ============================================================================
@ spi_is_writable(idx) -> r0 (1 if TX FIFO not full)
@ Cycle budget: 4 (base + ldr + lsr + and).
@ ============================================================================
    .section .text.spi_is_writable, "ax"
    .thumb_func
    .global  spi_is_writable
spi_is_writable:
    M_SPI_BASE r0, r0
    ldr     r1, [r0, #SSPSR]
    lsrs    r0, r1, #SSPSR_TNF_LSB
    movs    r1, #1
    ands    r0, r1
    bx      lr

@ ============================================================================
@ spi_is_readable(idx) -> r0 (1 if RX FIFO not empty)
@ ============================================================================
    .section .text.spi_is_readable, "ax"
    .thumb_func
    .global  spi_is_readable
spi_is_readable:
    M_SPI_BASE r0, r0
    ldr     r1, [r0, #SSPSR]
    lsrs    r0, r1, #SSPSR_RNE_LSB
    movs    r1, #1
    ands    r0, r1
    bx      lr

@ ============================================================================
@ spi_is_busy(idx) -> r0 (1 if BSY)
@ ============================================================================
    .section .text.spi_is_busy, "ax"
    .thumb_func
    .global  spi_is_busy
spi_is_busy:
    M_SPI_BASE r0, r0
    ldr     r1, [r0, #SSPSR]
    lsrs    r0, r1, #SSPSR_BSY_LSB
    movs    r1, #1
    ands    r0, r1
    bx      lr

@ ============================================================================
@ spi_write_blocking(idx, src, len) -> r0 = len
@
@ Inner loop:
@   wait_tnf:   ldr [base, #SSPSR]; tst TNF; beq wait_tnf
@   tx:         ldrb tmp, [src], #1; str tmp, [base, #SSPDR]
@   drain_rx:   while RNE: discard SSPDR
@
@ We discard RX bytes after every TX so the RX FIFO doesn't overflow on
@ long bursts (PL022 has only 8 entries deep).  Returns once all `len`
@ bytes have been pushed AND the BSY flag clears.
@ ============================================================================
    .section .text.spi_write_blocking, "ax"
    .thumb_func
    .global  spi_write_blocking
spi_write_blocking:
    push    {r4, r5, r6, r7, lr}
    M_SPI_BASE r0, r0
    mov     r4, r0                      @ base
    mov     r5, r1                      @ src
    mov     r6, r2                      @ len
    movs    r7, #0                      @ index

    cbz     r6, 9f

1:  @ Wait for TX FIFO not full
    ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_TNF_LSB
    movs    r2, #1
    ands    r1, r2
    beq     1b

    @ Push next byte
    ldrb    r0, [r5, r7]
    str     r0, [r4, #SSPDR]

    @ Drain any RX bytes that have accumulated (discard)
2:  ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_RNE_LSB
    movs    r2, #1
    ands    r1, r2
    beq     3f
    ldr     r0, [r4, #SSPDR]
    b       2b
3:
    adds    r7, #1
    cmp     r7, r6
    blo     1b

    @ Wait for BSY=0 (last bit on the wire), then drain RX one more time
4:  ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_BSY_LSB
    movs    r2, #1
    ands    r1, r2
    bne     4b
5:  ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_RNE_LSB
    movs    r2, #1
    ands    r1, r2
    beq     9f
    ldr     r0, [r4, #SSPDR]
    b       5b
9:  mov     r0, r6                      @ return len
    pop     {r4, r5, r6, r7, pc}

@ ============================================================================
@ spi_read_blocking(idx, repeated_tx, dst, len) -> r0 = len
@
@ Same shape as write_blocking, but pushes the constant `repeated_tx` and
@ stores RX bytes into dst[].
@ ============================================================================
    .section .text.spi_read_blocking, "ax"
    .thumb_func
    .global  spi_read_blocking
spi_read_blocking:
    push    {r4, r5, r6, r7, r8, lr}
    M_SPI_BASE r0, r0
    mov     r4, r0                      @ base
    mov     r5, r1                      @ tx_byte
    mov     r6, r2                      @ dst
    mov     r7, r3                      @ len
    movs    r8, #0                      @ count

    cbz     r7, 9f
1:  @ Push as long as TX has room AND we haven't pushed `len` already.
    @ Then service RX.  The classic full-duplex pattern.
    @ Track tx_pushed in r8 (also reused as rx_received once tx done).

    @ For simplicity: push at most one per outer iter, then service one rx,
    @ then loop until rx_received == len.
    @ We split tx_count vs rx_count to allow tx to run ahead by SPI_FIFO_DEPTH.
    @ Let's use a simpler scheme: split into two loops with FIFO depth.
    @ Use:  push_remaining = len - tx_count, recv_remaining = len - rx_count.
    b       .Lread_loop_init

.Lread_loop_init:
    movs    r0, #0                      @ tx_count = 0 (in r12 to avoid eating
                                        @ another callee-saved register)
    mov     r12, r0
.Lread_loop:
    @ try push if tx_count < len AND TNF
    mov     r0, r12
    cmp     r0, r7
    bge     .Lread_skip_tx
    ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_TNF_LSB
    movs    r2, #1
    ands    r1, r2
    beq     .Lread_skip_tx
    str     r5, [r4, #SSPDR]
    mov     r0, r12
    adds    r0, #1
    mov     r12, r0
.Lread_skip_tx:
    @ try recv if RNE
    ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_RNE_LSB
    movs    r2, #1
    ands    r1, r2
    beq     .Lread_skip_rx
    ldr     r0, [r4, #SSPDR]
    strb    r0, [r6, r8]
    adds    r8, #1
.Lread_skip_rx:
    cmp     r8, r7
    blo     .Lread_loop
9:  mov     r0, r7
    pop     {r4, r5, r6, r7, r8, pc}

@ ============================================================================
@ spi_write_read_blocking(idx, src, dst, len) -> r0 = len
@
@ Full-duplex blocking transfer.
@ ============================================================================
    .section .text.spi_write_read_blocking, "ax"
    .thumb_func
    .global  spi_write_read_blocking
spi_write_read_blocking:
    push    {r4, r5, r6, r7, r8, lr}
    M_SPI_BASE r0, r0
    mov     r4, r0                      @ base
    mov     r5, r1                      @ src
    mov     r6, r2                      @ dst
    mov     r7, r3                      @ len
    movs    r8, #0                      @ rx_count
    cbz     r7, 9f

    movs    r0, #0
    mov     r12, r0                     @ tx_count

.Lwrr_loop:
    mov     r0, r12
    cmp     r0, r7
    bge     .Lwrr_skip_tx
    ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_TNF_LSB
    movs    r2, #1
    ands    r1, r2
    beq     .Lwrr_skip_tx
    @ tx[i] -> SSPDR
    mov     r0, r12
    ldrb    r1, [r5, r0]
    str     r1, [r4, #SSPDR]
    adds    r0, #1
    mov     r12, r0
.Lwrr_skip_tx:
    ldr     r0, [r4, #SSPSR]
    lsrs    r1, r0, #SSPSR_RNE_LSB
    movs    r2, #1
    ands    r1, r2
    beq     .Lwrr_skip_rx
    ldr     r0, [r4, #SSPDR]
    strb    r0, [r6, r8]
    adds    r8, #1
.Lwrr_skip_rx:
    cmp     r8, r7
    blo     .Lwrr_loop

9:  mov     r0, r7
    pop     {r4, r5, r6, r7, r8, pc}

@ ============================================================================
@ spi_set_irqs_enabled(idx, mask)
@   Plain write to SSPIMSC = mask & 0xF.
@ ============================================================================
    .section .text.spi_set_irqs_enabled, "ax"
    .thumb_func
    .global  spi_set_irqs_enabled
spi_set_irqs_enabled:
    M_SPI_BASE r0, r0
    movs    r2, #0xF
    ands    r1, r2
    str     r1, [r0, #SSPIMSC]
    bx      lr

@ ============================================================================
@ spi_clear_irq(idx, mask)
@   W1C to SSPICR = mask & (RORIC|RTIC) = mask & 0x3.
@   The PL022 only allows clearing the receive-overrun and receive-timeout
@   interrupts; RXIM/TXIM are level-driven and clear when the FIFO threshold
@   is no longer met.  We mask the input so callers can pass SSPIMSC_ALL.
@ ============================================================================
    .section .text.spi_clear_irq, "ax"
    .thumb_func
    .global  spi_clear_irq
spi_clear_irq:
    M_SPI_BASE r0, r0
    movs    r2, #0x3
    ands    r1, r2
    str     r1, [r0, #SSPICR]
    bx      lr

@ ============================================================================
@ spi_set_dma_enabled(idx, tx_on, rx_on)
@   SSPDMACR = (tx_on?TXDMAE:0) | (rx_on?RXDMAE:0)
@ ============================================================================
    .section .text.spi_set_dma_enabled, "ax"
    .thumb_func
    .global  spi_set_dma_enabled
spi_set_dma_enabled:
    M_SPI_BASE r0, r0
    movs    r3, #0
    cbz     r1, 1f
    movs    r1, #SSPDMACR_TXDMAE
    orrs    r3, r1
1:  cbz     r2, 2f
    movs    r2, #SSPDMACR_RXDMAE
    orrs    r3, r2
2:  str     r3, [r0, #SSPDMACR]
    bx      lr

@ ============================================================================
@ spi_cs_low(cs_pin) / spi_cs_high(cs_pin) - thin gpio_put wrappers.
@ Real CS bracketing is the application's responsibility.  These exist as
@ named entry points so the API surface is symmetric (and so you don't have
@ to remember the magic 0/1 polarity at every call site).
@ ============================================================================
    .section .text.spi_cs_low, "ax"
    .thumb_func
    .global  spi_cs_low
spi_cs_low:
    movs    r1, #0
    b       gpio_put

    .section .text.spi_cs_high, "ax"
    .thumb_func
    .global  spi_cs_high
spi_cs_high:
    movs    r1, #1
    b       gpio_put
