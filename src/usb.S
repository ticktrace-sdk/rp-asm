@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://amken.io>
@
@ This file is part of the Amken RP2350 Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ usb.S - RP2350 USB device controller + minimal CDC-ACM stack (M4-H).
@
@ Datasheet ref:
@   - RP2350 datasheet rev 0.3 (Aug 2024) sec 13 (USB controller)
@   - RP2040 datasheet rev 1.x sec 4.1 (DPRAM layout - inherited verbatim)
@   - USB 2.0 spec ch 9 (standard requests)
@   - USB CDC 1.2 + PSTN spec (CDC-ACM class)
@
@ Public API (AAPCS):
@
@   usb_device_init()
@       Bring controller out of reset, mux PHY to internal, force VBUS detect
@       (since the Pico 2 doesn't have a VBUS-sense pin), enable interrupts,
@       set MAIN_CTRL.CONTROLLER_EN.  After this returns the controller is
@       waiting for bus reset / SETUP packets and the host enumeration starts.
@
@   usb_device_isr()
@       Must be installed at NVIC vector USBCTRL_IRQ (= 14) via
@       nvic_install_handler.  Handles BUS_RESET, SETUP_REQ, BUFF_STATUS.
@
@   usb_send_zlp(ep_num)
@       Push a zero-length packet on the IN side of EP ep_num.  Used at the
@       end of a control READ when host requested 0 bytes, and as the status
@       stage of a control WRITE.
@
@   usb_ep_send(ep_num, src, len)
@       Copy `len` bytes from `src` into the EP's IN buffer in DPRAM, then
@       set AVAILABLE+FULL+LENGTH on the buf_ctrl word so the controller
@       ships them on the next IN token.  Toggles PID DATA0/DATA1 internally.
@       Returns nothing.  Caller must ensure the EP IN buffer is free.
@
@   usb_ep_receive_arm(ep_num, len)
@       Arm an OUT endpoint for the next host packet of up to `len` bytes.
@       Sets AVAILABLE on the OUT buf_ctrl with the host-side length.
@
@   usb_get_received(ep_num, dst, len_max) -> r0
@       Copy up to len_max bytes from the EP's OUT buffer into dst.  Returns
@       the actual byte count taken from buf_ctrl.LENGTH_0.  Does NOT re-arm
@       the EP - call usb_ep_receive_arm() yourself.
@
@   cdc_putc(byte)
@       Push `byte` to the CDC TX ring.  If the ring is full and the IN EP
@       has space, flush as much as possible into the EP buffer and trigger
@       a transfer.
@
@   cdc_puts(str_ptr)
@       Convenience wrapper: cdc_putc each byte until NUL.
@
@   cdc_available -> r0
@       Returns # bytes currently buffered in the CDC RX ring.
@
@   cdc_getc -> r0
@       Returns one byte from the RX ring (or -1 if empty).
@
@ Cycle budgets:
@
@   usb_device_init                      ~80 cycles + reset settle (~40 cycles)
@   usb_ep_send (small payload N bytes)  ~30 + 4N cycles (memcpy + buf_ctrl)
@   usb_ep_receive_arm                   ~14 cycles (one buf_ctrl store)
@   ISR fast path (BUFF_STATUS, EP1 OUT) ~60 cycles (drain to ring, re-arm)
@   ISR SETUP path (GET_DESCRIPTOR Dev)  ~80 cycles (lookup + 18 B memcpy + arm)
@   ISR SET_ADDRESS                      ~30 cycles (buffer addr, send ZLP)
@
@ All driver state lives in .bss so the firmware can re-init at runtime.
@ =============================================================================

    .include "rp2350.inc"
    .include "usb.inc"
    .include "usb_descriptors.inc"

    .syntax unified
    .cpu    cortex-m33
    .thumb

@ ----------------------------------------------------------------------------
@ Driver state in .bss
@ ----------------------------------------------------------------------------
@   usb_pending_address    SET_ADDRESS deferred-write slot.  USB spec says
@                          we must complete the status stage at address 0,
@                          *then* update ADDR_ENDP.  ISR latches the requested
@                          address here and applies it on the next BUFF_STATUS
@                          for EP0_IN.
@   usb_configured         non-zero once SET_CONFIGURATION 1 has arrived.
@   usb_ep0_pid            current DATA toggle for EP0 IN  (0 = DATA0, 1 = DATA1)
@   usb_ep1_in_pid         data toggle for EP1 IN
@   usb_ep1_out_pid        data toggle for EP1 OUT
@
@   cdc_rx_buf[64]         RX ring - bytes received from host on EP1 OUT
@   cdc_rx_head, _tail     uint16_t head/tail indices (modulo 64)
@   cdc_tx_buf[64]         TX ring - bytes the firmware has queued via cdc_putc
@   cdc_tx_head, _tail     uint16_t head/tail indices
@   cdc_in_busy            non-zero while EP1 IN buffer is currently shipping
@                          and we must not stomp on it.
@ Each scalar is a .word so its symbol address is 4-byte aligned and
@ harness.py's `st_value & ~1` symbol lookup matches.  Wastes 3 bytes per
@ scalar; fine for v0.1.
    .section .bss.usb_state, "aw", %nobits
    .align   2
    .global  usb_pending_address
usb_pending_address:    .word 0
    .global  usb_configured
usb_configured:         .word 0
    @ USB has independent PID toggles per (endpoint, direction).  EP0 IN and
    @ EP0 OUT each get their own shadow.
    .global  usb_ep0_pid
usb_ep0_pid:            .word 0     @ EP0 IN PID shadow
    .global  usb_ep0_out_pid
usb_ep0_out_pid:        .word 0     @ EP0 OUT PID shadow (STATUS ZLP, etc.)
    @ Multi-packet IN state for EP0.  Set by _usb_ep0_start_tx; consumed
    @ chunk-by-chunk in _usb_handle_buff_status when the previous IN packet
    @ has completed.  Needed for any descriptor > 64 bytes (the full CDC
    @ config descriptor is 67).
    .global  usb_ep0_tx_src
usb_ep0_tx_src:         .word 0
    .global  usb_ep0_tx_remaining
usb_ep0_tx_remaining:   .word 0
    .global  usb_ep1_in_pid
usb_ep1_in_pid:         .word 0
    .global  usb_ep1_out_pid
usb_ep1_out_pid:        .word 0
    @ Set to 1 after the SET_LINE_CODING SETUP arrives so the BUFF_STATUS
    @ EP0 OUT handler knows the next packet is the 7-byte line coding payload
    @ (not a status-stage ZLP), and can inspect dwDTERate for the 1200-baud
    @ "reset to BOOTSEL" trick used by Pico tooling.
    .global  usb_setlc_pending
usb_setlc_pending:      .word 0
    @ Shadow of CDC DTR (wValue bit 0 of SET_CONTROL_LINE_STATE).  Set
    @ to 1 when the host has opened the tty, 0 when it's closed.  Demos
    @ that want to print a startup banner should wait for the 0->1 edge
    @ to guarantee the host is actually draining EP1 IN.
    .global  cdc_dtr
cdc_dtr:                .word 0
    @ Init-timing instrumentation: DWT CYCCNT snapshot the first time
    @ each milestone fires (0 if not yet observed).  Reading these
    @ alongside a free-running DWT_CYCCNT lets a demo report how long
    @ each enumeration phase took.  Cycles only — caller decodes to
    @ wall-clock by knowing the clock rate at that point.
    .global  usb_t_bus_reset
usb_t_bus_reset:        .word 0
    .global  usb_t_first_setup
usb_t_first_setup:      .word 0
    .global  usb_t_configured
usb_t_configured:       .word 0
    .global  usb_t_dtr
usb_t_dtr:              .word 0
    .global  cdc_in_busy
cdc_in_busy:            .word 0
    .global  cdc_rx_head
cdc_rx_head:            .word 0
    .global  cdc_rx_tail
cdc_rx_tail:            .word 0
    .global  cdc_tx_head
cdc_tx_head:            .word 0
    .global  cdc_tx_tail
cdc_tx_tail:            .word 0

    @ Ring must be larger than any single logical write the firmware emits,
    @ because cdc_putc drops bytes when the ring is full (no back-pressure).
    @ A 64-byte EP1 IN packet may be in flight (cdc_in_busy=1) while the
    @ next cdc_puts queues a new line; with a 64-byte ring, multi-field
    @ status lines (e.g. otp_usb_demo) truncate.  256 absorbs one in-flight
    @ packet plus a 192-byte log line.
    .equ CDC_RING_SIZE, 256
    .equ CDC_RING_MASK, (CDC_RING_SIZE - 1)

@ ----------------------------------------------------------------------------
@ Phase-timing helper: store DWT_CYCCNT into \addr the first time it fires
@ (no-op if \addr is already non-zero).  Clobbers r0, r1.  Uses local label
@ 99f, which is a re-usable forward reference - safe to invoke multiple
@ times in the same function.
@ ----------------------------------------------------------------------------
.macro USB_LOG_PHASE addr
    ldr     r0, =\addr
    ldr     r1, [r0]
    cbnz    r1, 99f
    movw    r1, #0x1004                           @ DWT_CYCCNT low
    movt    r1, #0xE000                           @ DWT_CYCCNT high
    ldr     r1, [r1]
    str     r1, [r0]
99:
.endm

    .align   2
    .global  cdc_rx_buf
cdc_rx_buf:             .space CDC_RING_SIZE
    .global  cdc_tx_buf
cdc_tx_buf:             .space CDC_RING_SIZE

@ ============================================================================
@ Section 1: Controller bring-up.
@ ============================================================================

@ ----------------------------------------------------------------------------
@ usb_device_init - bring USB controller out of reset, configure PHY mux,
@                   force VBUS detect (since Pico 2 has no VBUS sense pin),
@                   enable interrupts, MAIN_CTRL = CONTROLLER_EN.
@ Clobbers: r0-r3.
@ ----------------------------------------------------------------------------
    .section .text.usb_device_init, "ax"
    .thumb_func
    .global  usb_device_init
usb_device_init:
    push    {r4, lr}

    @ ---- 1. Bring usbctrl out of reset (RESETS bit 28) -------------------
    movs    r1, #1
    lsls    r1, r1, #RESETS_usbctrl       @ r1 = 1 << 28
    ldr     r0, =RESETS_BASE + ATOMIC_CLR + RESETS_RESET
    str     r1, [r0]
    @ Spin until RESET_DONE shows the bit set.
    ldr     r0, =RESETS_BASE + RESETS_RESET_DONE
1:  ldr     r2, [r0]
    ands    r2, r1
    beq     1b

    @ ---- 2. Clear all DPRAM (4 KiB) so EP buf_ctrl + ep_ctrl start at 0 --
    ldr     r0, =USBCTRL_DPRAM_BASE
    movs    r1, #0
    movs    r2, #(0x1000 / 4)             @ 1024 words = 4 KiB
2:  str     r1, [r0], #4
    subs    r2, #1
    bne     2b

    @ ---- 3. PHY: USB_MUXING = TO_PHY | SOFTCON --------------------------
    ldr     r4, =USBCTRL_REGS_BASE
    movs    r0, #(USB_MUXING_TO_PHY | USB_MUXING_SOFTCON)
    str     r0, [r4, #USB_USB_MUXING]

    @ ---- 4. Force VBUS detect on (Pico 2 has no VBUS sense pin) ---------
    @ USB_PWR = VBUS_DETECT | VBUS_DETECT_OVERRIDE_EN
    movs    r0, #(USB_PWR_VBUS_DETECT | USB_PWR_VBUS_DETECT_OVERRIDE_EN)
    str     r0, [r4, #USB_USB_PWR]

    @ ---- 5. MAIN_CTRL.CONTROLLER_EN, device mode (HOST_NDEVICE = 0) -----
    movs    r0, #USB_MAIN_CTRL_CTRL_EN
    str     r0, [r4, #USB_MAIN_CTRL]

    @ ---- 6. Enable EP0 SETUP via SIE_CTRL (raise irq on SETUP packet) ---
    @ Bit 29 (EP0_INT_1BUF) = irq for EP0 buffer-1 transactions.  We
    @ specifically want SETUP_REQ + BUFF_STATUS + BUS_RESET, set in INTE
    @ below; SIE_CTRL needs the pull-up for device enumeration too.
    ldr     r0, =USB_SIE_CTRL_PULLUP_EN | USB_SIE_CTRL_EP0_INT_1BUF
    str     r0, [r4, #USB_SIE_CTRL]

    @ ---- 7. INTE: SETUP_REQ | BUFF_STATUS | BUS_RESET -------------------
    ldr     r0, =(USB_INT_SETUP_REQ | USB_INT_BUFF_STATUS | USB_INT_BUS_RESET)
    str     r0, [r4, #USB_INTE]

    pop     {r4, pc}

@ ============================================================================
@ Section 2: Endpoint primitives.
@ ============================================================================

@ ----------------------------------------------------------------------------
@ usb_ep_buf_ctrl_addr(ep_num, dir_in) -> r0
@   r0 = ep_num (0..15)
@   r1 = dir_in (0 = OUT, 1 = IN)
@ Returns absolute address of the corresponding ep_buf_ctrl word.
@   addr = DPRAM_BASE + 0x80 + 8*ep + (dir_in ? 0 : 4)
@ Clobbers r2, r3 (none of the input regs).
@ ----------------------------------------------------------------------------
    .section .text.usb_ep_buf_ctrl_addr, "ax"
    .thumb_func
    .global  usb_ep_buf_ctrl_addr
usb_ep_buf_ctrl_addr:
    ldr     r2, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL
    lsls    r3, r0, #3                    @ ep * 8
    add     r2, r3
    @ dir_in: IN = +0, OUT = +4 (ep_buf_ctrl[n].in then ep_buf_ctrl[n].out)
    cbnz    r1, 1f
    adds    r2, #4
1:  mov     r0, r2
    bx      lr

@ ----------------------------------------------------------------------------
@ usb_ep_send(ep_num, src, len)
@   r0 = ep_num
@   r1 = src
@   r2 = len  (0..64)
@
@ Copies `len` bytes into the EP buffer in DPRAM and writes buf_ctrl with
@ AVAILABLE | FULL | LENGTH | PID, then toggles the per-EP PID shadow.
@
@ Buffer locations:
@   EP0:  DPRAM 0x100..0x140
@   EP1:  DPRAM 0x1C0..0x200
@   EP2:  DPRAM 0x200..0x208 (interrupt notification, max 8 bytes)
@
@ For other EPs the buffer must already be configured in ep_ctrl.
@ ----------------------------------------------------------------------------
    .section .text.usb_ep_send, "ax"
    .thumb_func
    .global  usb_ep_send
usb_ep_send:
    push    {r4, r5, r6, r7, lr}

    @ Compute buffer address by EP -----------------------------------------
    @  if ep == 0: 0x100  else if ep == 1: 0x1C0  else if ep == 2: 0x200
    ldr     r3, =USBCTRL_DPRAM_BASE
    cmp     r0, #0
    bne     2f
    add     r3, r3, #USB_DPRAM_EP0_BUF0           @ 0x100
    b       9f
2:  cmp     r0, #1
    bne     3f
    add     r3, r3, #USB_EP1_IN_BUF_OFFSET        @ 0x1C0
    b       9f
3:  cmp     r0, #2
    bne     4f
    add     r3, r3, #USB_EP2_IN_BUF_OFFSET        @ 0x200
    b       9f
4:  @ Unhandled EP - default to EP0 buf to avoid bus fault.
    add     r3, r3, #USB_DPRAM_EP0_BUF0
9:
    @ r3 = buffer base
    @ Copy len bytes from r1 to r3 (byte-by-byte; payloads are tiny) -------
    mov     r4, r1                                @ src
    mov     r5, r3                                @ dst
    mov     r6, r2                                @ len shadow
    cbz     r2, 11f                               @ len = 0 -> skip copy
10: ldrb    r7, [r4], #1
    strb    r7, [r5], #1
    subs    r2, #1
    bne     10b
11:
    @ Build buf_ctrl word ---------------------------------------------------
    @  bits [9:0]  = LENGTH (= len)
    @  bit  10     = AVAILABLE
    @  bit  13     = PID (DATA0/1) - we toggle a per-EP shadow byte
    @  bit  26     = FULL (set to indicate buffer has data for IN xfer)
    @  bit  15     = LAST (single-buffer transfer marker)
    @
    @ Resolve PID shadow: r5 = address of usb_epN_pid; current value in r7
    cmp     r0, #0
    bne     20f
    ldr     r5, =usb_ep0_pid
    b       29f
20: cmp     r0, #1
    bne     21f
    ldr     r5, =usb_ep1_in_pid
    b       29f
21: @ EP2: don't track PID separately; we rarely ship from it.  Reuse ep0_pid.
    ldr     r5, =usb_ep0_pid
29:
    ldrb    r7, [r5]                              @ current PID (0 or 1)
    @ Toggle for next time
    eors    r7, r7, #1
    strb    r7, [r5]
    @ But the buffer we're about to ship uses the *previous* PID; reload it.
    eors    r7, r7, #1                            @ undo

    @ buf_ctrl = LEN | AVAIL | FULL | LAST | (PID<<13)
    @ Combined mask 0x0400 | 0x8000 | 0x04000000 = 0x04008400 - too big for
    @ a movs immediate, so load via constant pool.
    mov     r4, r6                                @ len
    ldr     r2, =(USB_BUFCTRL_AVAILABLE_0 | USB_BUFCTRL_FULL_0 | USB_BUFCTRL_LAST_0)
    orrs    r4, r2
    @ PID
    cbz     r7, 30f
    ldr     r2, =USB_BUFCTRL_PID_0_DATA1
    orrs    r4, r2
30:
    @ Compute buf_ctrl address.  EP IN side: DPRAM + 0x80 + 8*ep
    ldr     r2, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL
    lsls    r3, r0, #3
    add     r2, r3
    str     r4, [r2]

    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ usb_send_zlp(ep_num)
@   r0 = ep_num
@ Sends a zero-length packet on the IN side of EP ep_num.
@ ----------------------------------------------------------------------------
    .section .text.usb_send_zlp, "ax"
    .thumb_func
    .global  usb_send_zlp
usb_send_zlp:
    push    {lr}
    movs    r1, #0
    movs    r2, #0
    bl      usb_ep_send
    pop     {pc}

@ ----------------------------------------------------------------------------
@ usb_ep_receive_arm(ep_num, len)
@   r0 = ep_num
@   r1 = len  (max bytes the EP will accept on next OUT token)
@ Sets buf_ctrl OUT for this EP with AVAILABLE | LENGTH = len.
@ ----------------------------------------------------------------------------
    .section .text.usb_ep_receive_arm, "ax"
    .thumb_func
    .global  usb_ep_receive_arm
usb_ep_receive_arm:
    push    {r4, lr}
    mov     r4, r1

    @ Resolve PID shadow for this EP OUT (independent from EP IN side).
    cmp     r0, #0
    bne     1f
    ldr     r2, =usb_ep0_out_pid
    b       9f
1:  ldr     r2, =usb_ep1_out_pid
9:  ldrb    r3, [r2]
    @ Toggle for the *next* call; the bit we set in buf_ctrl now is the PID
    @ we expect to receive.
    eors    r3, r3, #1
    strb    r3, [r2]
    eors    r3, r3, #1                            @ current PID

    @ Build buf_ctrl
    movs    r1, #USB_BUFCTRL_AVAILABLE_0 >> 10
    lsls    r1, r1, #10                           @ AVAILABLE
    orrs    r4, r1
    cbz     r3, 10f
    ldr     r1, =USB_BUFCTRL_PID_0_DATA1
    orrs    r4, r1
10:
    @ buf_ctrl OUT addr = DPRAM + 0x80 + 8*ep + 4
    ldr     r1, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL + 4
    lsls    r2, r0, #3
    add     r1, r2
    str     r4, [r1]

    pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ usb_get_received(ep_num, dst, len_max) -> r0
@   r0 = ep_num
@   r1 = dst
@   r2 = len_max
@ Reads buf_ctrl OUT, copies min(LENGTH, len_max) bytes from the OUT buffer
@ into dst, returns the byte count taken.  Does NOT re-arm.
@ ----------------------------------------------------------------------------
    .section .text.usb_get_received, "ax"
    .thumb_func
    .global  usb_get_received
usb_get_received:
    push    {r4, r5, r6, lr}

    @ Read buf_ctrl OUT
    ldr     r3, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL + 4
    lsls    r4, r0, #3
    add     r3, r4
    ldr     r3, [r3]                              @ buf_ctrl
    @ length = bits [9:0]
    movw    r4, #0x3FF
    and     r3, r3, r4                            @ r3 = received len
    @ min(received, len_max)
    cmp     r3, r2
    it      hi
    movhi   r3, r2

    @ Compute buffer address
    ldr     r4, =USBCTRL_DPRAM_BASE
    cmp     r0, #0
    bne     2f
    add     r4, r4, #USB_DPRAM_EP0_BUF0
    b       9f
2:  cmp     r0, #1
    bne     3f
    add     r4, r4, #USB_EP1_OUT_BUF_OFFSET
    b       9f
3:  add     r4, r4, #USB_DPRAM_EP0_BUF0
9:
    mov     r5, r3                                @ count to copy (= return)
    mov     r6, r3                                @ shadow
    cbz     r3, 11f
10: ldrb    r0, [r4], #1
    strb    r0, [r1], #1
    subs    r3, #1
    bne     10b
11:
    mov     r0, r6
    pop     {r4, r5, r6, pc}

@ ============================================================================
@ Section 3: ISR.  Installed via nvic_install_handler at vector USBCTRL_IRQ.
@ ============================================================================

@ ----------------------------------------------------------------------------
@ usb_device_isr - handle controller interrupts.
@
@ Order of checks (matches RP2350 datasheet sec 13.4):
@   1. BUS_RESET    - clear our state, ADDR_ENDP <- 0
@   2. SETUP_REQ    - parse 8-byte SETUP at DPRAM[0]; dispatch
@   3. BUFF_STATUS  - per-EP transfer completed; for EP0 IN, apply pending
@                     SET_ADDRESS; for EP1 OUT, drain into RX ring
@                     and re-arm; for EP1 IN, mark cdc_in_busy = 0 and
@                     try to push more from TX ring.
@
@ Each block W1Cs its own status bit so the line can drop once we're done.
@ ----------------------------------------------------------------------------
    .section .text.usb_device_isr, "ax"
    .thumb_func
    .global  usb_device_isr
usb_device_isr:
    push    {r4, r5, r6, r7, lr}
    ldr     r4, =USBCTRL_REGS_BASE
    ldr     r5, [r4, #USB_INTS]                   @ active masked interrupts

    @ ---- 1. BUS_RESET ---------------------------------------------------
    movs    r6, #1
    lsls    r6, r6, #12                           @ USB_INT_BUS_RESET = 1<<12
    tst     r5, r6
    beq     .Lnobr
    bl      _usb_handle_bus_reset
    @ W1C BUS_RESET in SIE_STATUS so it can re-fire
    ldr     r0, =USB_SIE_STATUS_W_BUS_RESET
    str     r0, [r4, #USB_SIE_STATUS]
.Lnobr:

    @ ---- 2. SETUP_REQ ---------------------------------------------------
    movs    r6, #1
    lsls    r6, r6, #16                           @ USB_INT_SETUP_REQ
    tst     r5, r6
    beq     .Lnosetup
    bl      _usb_handle_setup
    @ W1C SETUP_REC bit in SIE_STATUS
    ldr     r0, =USB_SIE_STATUS_W_SETUP_REC
    str     r0, [r4, #USB_SIE_STATUS]
.Lnosetup:

    @ ---- 3. BUFF_STATUS -------------------------------------------------
    movs    r6, #1
    lsls    r6, r6, #4                            @ USB_INT_BUFF_STATUS
    tst     r5, r6
    beq     .Lnobuf
    bl      _usb_handle_buff_status
.Lnobuf:

    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ _usb_handle_bus_reset - clear ADDR_ENDP, reset our shadow state.
@ ----------------------------------------------------------------------------
    .section .text._usb_handle_bus_reset, "ax"
    .thumb_func
_usb_handle_bus_reset:
    USB_LOG_PHASE usb_t_bus_reset
    push    {lr}
    ldr     r0, =USBCTRL_REGS_BASE
    movs    r1, #0
    str     r1, [r0, #USB_ADDR_ENDP]              @ device address = 0
    @ Clear all the booleans / PID toggles
    ldr     r0, =usb_pending_address
    movs    r1, #0
    strb    r1, [r0]                              @ pending_address
    ldr     r0, =usb_configured
    strb    r1, [r0]
    ldr     r0, =usb_ep0_pid
    strb    r1, [r0]
    ldr     r0, =usb_ep0_out_pid
    strb    r1, [r0]
    ldr     r0, =usb_ep1_in_pid
    strb    r1, [r0]
    ldr     r0, =usb_ep1_out_pid
    strb    r1, [r0]
    ldr     r0, =cdc_in_busy
    strb    r1, [r0]
    pop     {pc}

@ ----------------------------------------------------------------------------
@ _usb_handle_setup - parse SETUP packet at DPRAM[0..7] and dispatch.
@
@ SETUP packet layout (USB 2.0 sec 9.3):
@   off 0: bmRequestType  (direction | type | recipient)
@   off 1: bRequest
@   off 2: wValue (LE 16-bit)
@   off 4: wIndex (LE 16-bit)
@   off 6: wLength (LE 16-bit)
@
@ We handle the absolute minimum to enumerate as a CDC-ACM device:
@   GET_DESCRIPTOR (Device, Config, String)
@   SET_ADDRESS                       deferred-write
@   SET_CONFIGURATION                 arm bulk endpoints
@   GET_CONFIGURATION                 reply with usb_configured
@   CDC SET_LINE_CODING               accept 7 bytes on EP0 OUT, ZLP status
@   CDC GET_LINE_CODING               7-byte canned reply
@   CDC SET_CONTROL_LINE_STATE        ZLP
@
@ Anything else: STALL EP0 by writing EP_STALL_ARM and setting buf_ctrl.STALL.
@
@ The function also re-arms EP0 OUT for the next status-stage 0-byte packet
@ where applicable (e.g. after a control-IN such as GET_DESCRIPTOR the host
@ will send a 0-byte OUT to acknowledge).
@ ----------------------------------------------------------------------------
    .section .text._usb_handle_setup, "ax"
    .thumb_func
_usb_handle_setup:
    USB_LOG_PHASE usb_t_first_setup
    push    {r4, r5, r6, r7, lr}

    @ Reset EP0 PID shadows to DATA1 (per USB spec - first DATA stage packet
    @ and the STATUS ZLP are both DATA1; we store 1 so usb_ep_send /
    @ usb_ep_receive_arm pick DATA1 then toggle.  IN and OUT are independent.
    ldr     r0, =usb_ep0_pid
    movs    r1, #1
    strb    r1, [r0]
    ldr     r0, =usb_ep0_out_pid
    strb    r1, [r0]

    @ Read SETUP packet
    ldr     r0, =USBCTRL_DPRAM_BASE + USB_DPRAM_SETUP_PACKET
    ldrb    r4, [r0, #0]                          @ bmRequestType
    ldrb    r5, [r0, #1]                          @ bRequest
    ldrh    r6, [r0, #2]                          @ wValue
    ldrh    r7, [r0, #6]                          @ wLength

    @ ---- Dispatch on bRequest -------------------------------------------

    @ SET_ADDRESS (5)
    cmp     r5, #USB_REQ_SET_ADDRESS
    bne     .Lnot_setaddr
    @ wValue = new address (low 7 bits).  USB spec: complete status stage at
    @ address 0, *then* update ADDR_ENDP.  We latch the requested address
    @ and apply it after the EP0 IN ZLP completes (BUFF_STATUS handler).
    ldr     r0, =usb_pending_address
    strb    r6, [r0]                              @ keep low 8 bits of wValue
    movs    r0, #0
    bl      usb_send_zlp                          @ status stage
    b       .Lsetup_done

.Lnot_setaddr:

    @ GET_DESCRIPTOR (6)
    cmp     r5, #USB_REQ_GET_DESCRIPTOR
    bne     .Lnot_getdesc
    @ wValue high byte = descriptor type, low byte = index
    @ Walk usb_descriptor_table searching for (type, index)
    mov     r0, r6                                @ wValue (preserved across)
    mov     r1, r7                                @ wLength
    bl      _usb_send_descriptor
    b       .Lsetup_done
.Lnot_getdesc:

    @ SET_CONFIGURATION (9)
    cmp     r5, #USB_REQ_SET_CONFIGURATION
    bne     .Lnot_setcfg
    ldr     r0, =usb_configured
    strb    r6, [r0]                              @ low byte of wValue (0 or 1)
    @ Snapshot the configured-time the first time SET_CONFIG sets it to
    @ non-zero (host has finished standard enumeration at this point).
    cbz     r6, .Lskip_cfg_t
    USB_LOG_PHASE usb_t_configured
.Lskip_cfg_t:
    @ Configure EP1 OUT, EP1 IN, EP2 IN in DPRAM ep_ctrl table
    bl      _usb_setup_endpoints
    @ Arm EP1 OUT to receive first packet (64 bytes)
    movs    r0, #1
    movs    r1, #USB_EP_BULK_MAX_PACKET
    bl      usb_ep_receive_arm
    @ Send ZLP status stage
    movs    r0, #0
    bl      usb_send_zlp
    b       .Lsetup_done
.Lnot_setcfg:

    @ GET_CONFIGURATION (8) - return one byte = usb_configured
    cmp     r5, #USB_REQ_GET_CONFIGURATION
    bne     .Lnot_getcfg
    ldr     r0, =usb_configured
    movs    r1, r0                                @ src = &usb_configured
    movs    r0, #0                                @ ep0
    movs    r2, #1                                @ 1 byte
    bl      usb_ep_send
    b       .Lsetup_done
.Lnot_getcfg:

    @ GET_STATUS (0) - reply 0x0000 (self-powered, no remote wake)
    cmp     r5, #USB_REQ_GET_STATUS
    bne     .Lnot_getstatus
    ldr     r0, =_usb_zero_status
    movs    r1, r0
    movs    r0, #0
    movs    r2, #2
    bl      usb_ep_send
    b       .Lsetup_done
.Lnot_getstatus:

    @ ---- CDC class requests --------------------------------------------
    @ bmRequestType.type == CLASS (bits 6:5 = 01 -> 0x20 mask)
    movs    r0, #0x60                             @ type field mask
    and     r0, r4
    cmp     r0, #0x20                             @ class
    bne     .Lstall

    @ SET_LINE_CODING (0x20) - host will send 7 bytes on EP0 OUT.  We
    @ ack with a ZLP, arm EP0 OUT to swallow the 7-byte data stage, and
    @ remember that the next EP0 OUT buffer-status should be inspected
    @ (so we can implement the 1200-baud BOOTSEL trick).
    cmp     r5, #USB_CDC_REQ_SET_LINE_CODING
    bne     .Lnot_setlc
    ldr     r0, =usb_setlc_pending
    movs    r1, #1
    str     r1, [r0]
    movs    r0, #0
    movs    r1, #7
    bl      usb_ep_receive_arm
    @ The status stage is the host receiving a ZLP IN.  We send it now;
    @ silicon serializes data + status correctly.
    movs    r0, #0
    bl      usb_send_zlp
    b       .Lsetup_done
.Lnot_setlc:

    @ GET_LINE_CODING (0x21) - reply 7 bytes: 115200 8N1
    cmp     r5, #USB_CDC_REQ_GET_LINE_CODING
    bne     .Lnot_getlc
    ldr     r1, =_usb_line_coding_default
    movs    r0, #0
    movs    r2, #7
    bl      usb_ep_send
    b       .Lsetup_done
.Lnot_getlc:

    @ SET_CONTROL_LINE_STATE (0x22) - wValue bit 0 is DTR (host userspace
    @ has opened the tty), bit 1 is RTS.  We expose DTR via cdc_dtr so
    @ demos can print their banner on the rising edge instead of right
    @ after enumeration (banner-before-tty-open is otherwise dropped on
    @ the floor because the host doesn't pull bulk IN until DTR is high).
    cmp     r5, #USB_CDC_REQ_SET_CONTROL_LINE_STATE
    bne     .Lstall
    ldr     r0, =cdc_dtr
    and     r1, r6, #1                            @ wValue & DTR bit
    str     r1, [r0]
    cbz     r1, .Lskip_dtr_t                      @ only record on DTR=1
    USB_LOG_PHASE usb_t_dtr
.Lskip_dtr_t:
    movs    r0, #0
    bl      usb_send_zlp
    b       .Lsetup_done

.Lstall:
    @ Unhandled request: stall EP0 IN by setting STALL bit + EP_STALL_ARM
    ldr     r0, =USBCTRL_REGS_BASE
    movs    r1, #1                                @ EP0 IN bit
    str     r1, [r0, #USB_EP_STALL_ARM]
    ldr     r0, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL
    movs    r1, #USB_BUFCTRL_STALL >> 8
    lsls    r1, #8
    str     r1, [r0]

.Lsetup_done:
    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ _usb_send_descriptor(wValue, wLength)
@   r0 = wValue (high byte = type, low byte = index)
@   r1 = wLength
@ Walks usb_descriptor_table; for the matching entry, copies min(len, wLength)
@ bytes into DPRAM EP0 IN buffer and arms it.  Stalls if no match.
@ ----------------------------------------------------------------------------
    .section .text._usb_send_descriptor, "ax"
    .thumb_func
    .global  _usb_send_descriptor
_usb_send_descriptor:
    push    {r4, r5, r6, r7, lr}
    @ r4 = type (high byte of wValue), r5 = index (low byte)
    lsrs    r4, r0, #8
    movs    r2, #0xFF
    and     r5, r0, r2
    mov     r6, r1                                @ wLength

    ldr     r7, =usb_descriptor_table
    ldr     r3, =usb_descriptor_table_end
.Ldesc_loop:
    cmp     r7, r3
    bge     .Ldesc_stall
    @ Each entry: ptr(4), len(2), type(1), idx(1) = 8 bytes
    ldrb    r0, [r7, #6]                          @ entry.type
    cmp     r0, r4
    bne     .Ldesc_skip
    ldrb    r0, [r7, #7]                          @ entry.idx
    cmp     r0, r5
    bne     .Ldesc_skip
    @ Match!  Send the descriptor, fragmenting into 64-byte EP0 IN packets
    @ if necessary (config descriptor is 67 bytes on CDC-ACM).
    ldr     r1, [r7, #0]                          @ src ptr
    ldrh    r2, [r7, #4]                          @ desc len
    cmp     r2, r6
    it      hi
    movhi   r2, r6                                @ min(desclen, wLength)
    bl      _usb_ep0_start_tx
    @ Arm EP0 OUT for the host's status-stage ZLP
    movs    r0, #0
    movs    r1, #0
    bl      usb_ep_receive_arm
    pop     {r4, r5, r6, r7, pc}
.Ldesc_skip:
    adds    r7, #USB_DESC_TABLE_ENTRY_SIZE
    b       .Ldesc_loop
.Ldesc_stall:
    @ No descriptor for this (type,index): properly stall EP0 IN.  EP0
    @ requires BOTH the per-EP STALL_ARM bit AND the BUFF_CTRL.STALL bit
    @ - setting only EP_STALL_ARM causes the device to NAK forever
    @ rather than send a STALL handshake, and the host then waits the
    @ full USB_CTRL_GET_TIMEOUT (~5 s on Linux) before giving up.  This
    @ was the dominant component of our slow enumeration: every
    @ GET_DESCRIPTOR for an unsupported type (Device Qualifier, BOS,
    @ etc.) burned the full 5-second timeout.
    ldr     r0, =USBCTRL_REGS_BASE
    movs    r1, #1
    str     r1, [r0, #USB_EP_STALL_ARM]
    ldr     r0, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL
    movs    r1, #USB_BUFCTRL_STALL >> 8
    lsls    r1, #8
    str     r1, [r0]
    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ _usb_ep0_start_tx(src, total_len) - begin a multi-packet EP0 IN transfer.
@   r1 = src
@   r2 = total_len  (may be > 64; we fragment into 64-byte EP0 IN packets)
@
@ Saves (src + 64, total_len - first_chunk) into usb_ep0_tx_{src,remaining}
@ for the BUFF_STATUS handler to pick up, then ships the first chunk.
@ Clobbers r0-r3.
@ ----------------------------------------------------------------------------
    .section .text._usb_ep0_start_tx, "ax"
    .thumb_func
    .global  _usb_ep0_start_tx
_usb_ep0_start_tx:
    push    {r4, r5, lr}
    mov     r4, r1                                @ src
    mov     r5, r2                                @ total_len

    @ chunk = min(total_len, 64)
    movs    r3, #64
    cmp     r5, r3
    it      ls
    movls   r3, r5

    @ Save tail (src + chunk, remaining = total_len - chunk) for the next IRQ.
    add     r1, r4, r3                            @ next src
    subs    r2, r5, r3                            @ remaining
    ldr     r0, =usb_ep0_tx_src
    str     r1, [r0]
    ldr     r0, =usb_ep0_tx_remaining
    str     r2, [r0]

    @ Ship the first chunk now.
    movs    r0, #0                                @ EP0
    mov     r1, r4                                @ src
    mov     r2, r3                                @ len
    bl      usb_ep_send
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ _usb_ep0_tx_continue - ship the next chunk of a pending EP0 IN transfer.
@ Called from _usb_handle_buff_status when EP0 IN completes and there are
@ still bytes left in usb_ep0_tx_remaining.  Returns r0 = 1 if a chunk was
@ sent (caller should NOT also try to apply pending SET_ADDRESS), 0 if no
@ pending transfer.  Clobbers r0-r3.
@ ----------------------------------------------------------------------------
    .section .text._usb_ep0_tx_continue, "ax"
    .thumb_func
    .global  _usb_ep0_tx_continue
_usb_ep0_tx_continue:
    push    {r4, r5, lr}
    ldr     r0, =usb_ep0_tx_remaining
    ldr     r5, [r0]
    cbz     r5, 9f                                @ nothing pending -> return 0
    ldr     r0, =usb_ep0_tx_src
    ldr     r4, [r0]                              @ src

    @ chunk = min(remaining, 64)
    movs    r3, #64
    cmp     r5, r3
    it      ls
    movls   r3, r5

    @ Advance state
    add     r1, r4, r3
    subs    r2, r5, r3
    ldr     r0, =usb_ep0_tx_src
    str     r1, [r0]
    ldr     r0, =usb_ep0_tx_remaining
    str     r2, [r0]

    @ Send chunk
    movs    r0, #0
    mov     r1, r4
    mov     r2, r3
    bl      usb_ep_send
    movs    r0, #1
    pop     {r4, r5, pc}
9:  movs    r0, #0
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ _usb_setup_endpoints - configure ep_ctrl entries for EP1 OUT, EP1 IN, EP2 IN.
@ Called after SET_CONFIGURATION 1.
@ ----------------------------------------------------------------------------
    .section .text._usb_setup_endpoints, "ax"
    .thumb_func
_usb_setup_endpoints:
    @ Each EP needs INTERRUPT_PER_BUFF (bit 29) so the controller sets the
    @ corresponding BUFF_STATUS bit on buffer completion and raises the USB
    @ IRQ.  Without it the buffer transfers silently and the ISR never sees
    @ EP1 OUT bytes arrive or EP1 IN packets complete.
    @ ep_ctrl[1].in   @ DPRAM + 0x008  (EP1 IN, bulk, 64 bytes)
    ldr     r0, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_CTRL_BASE
    ldr     r1, =(USB_EPCTRL_ENABLE | USB_EPCTRL_INTERRUPT_PER_BUF | USB_EPCTRL_TYPE_BULK | USB_EP1_IN_BUF_OFFSET)
    str     r1, [r0, #0]                          @ ep_ctrl[1].in

    @ ep_ctrl[1].out  @ DPRAM + 0x00C  (EP1 OUT, bulk, 64 bytes)
    ldr     r1, =(USB_EPCTRL_ENABLE | USB_EPCTRL_INTERRUPT_PER_BUF | USB_EPCTRL_TYPE_BULK | USB_EP1_OUT_BUF_OFFSET)
    str     r1, [r0, #4]                          @ ep_ctrl[1].out

    @ ep_ctrl[2].in   @ DPRAM + 0x010  (EP2 IN, interrupt, 8 bytes)
    ldr     r1, =(USB_EPCTRL_ENABLE | USB_EPCTRL_INTERRUPT_PER_BUF | USB_EPCTRL_TYPE_INTERRUPT | USB_EP2_IN_BUF_OFFSET)
    str     r1, [r0, #8]                          @ ep_ctrl[2].in

    bx      lr

@ ----------------------------------------------------------------------------
@ _usb_handle_buff_status - per-EP transfer completed.
@ ----------------------------------------------------------------------------
    .section .text._usb_handle_buff_status, "ax"
    .thumb_func
_usb_handle_buff_status:
    push    {r4, r5, r6, r7, lr}
    ldr     r4, =USBCTRL_REGS_BASE
    ldr     r5, [r4, #USB_BUFF_STATUS]            @ raw bits

    @ EP0 IN (bit 0): either continue a multi-packet IN transfer (e.g. the
    @ 67-byte config descriptor split into 64 + 3) or apply deferred
    @ SET_ADDRESS if a control transfer just finished.
    movs    r6, #1
    tst     r5, r6
    beq     .Lnoep0in
    @ W1C bit 0 BEFORE doing more work so a follow-on usb_ep_send -> buf_ctrl
    @ store sees a clean status (avoid races with a quick host).
    movs    r0, #1
    str     r0, [r4, #USB_BUFF_STATUS]
    bl      _usb_ep0_tx_continue
    cbnz    r0, .Lnoep0in                         @ shipped another chunk - done
    @ No more chunks pending; consider this the end of a control transfer.
    ldr     r0, =usb_pending_address
    ldrb    r1, [r0]
    cbz     r1, .Lnoep0in
    @ Apply: ADDR_ENDP = pending; clear pending
    str     r1, [r4, #USB_ADDR_ENDP]
    movs    r2, #0
    strb    r2, [r0]
.Lnoep0in:

    @ EP0 OUT (bit 1) - either the host's ZLP status stage (nothing to
    @ do) or the 7-byte SET_LINE_CODING data stage if we previously set
    @ usb_setlc_pending.  In the latter case inspect dwDTERate: if it's
    @ 1200 the host is signalling "reboot into BOOTSEL" (matches the
    @ tinygo/picotool convention).
    movs    r6, #2
    tst     r5, r6
    beq     .Lnoep0out
    ldr     r0, =usb_setlc_pending
    ldr     r1, [r0]
    cbz     r1, .Lnoep0out_clr
    movs    r1, #0
    str     r1, [r0]                              @ consume the pending flag
    @ dwDTERate is the first 4 bytes of the LINE_CODING struct at the
    @ start of the EP0 OUT data buffer (== EP0_BUF0 since EP0 IN/OUT
    @ share that 64-byte region).
    ldr     r0, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP0_BUF0
    ldr     r0, [r0]                              @ r0 = dwDTERate (little-endian)
    movw    r1, #1200
    cmp     r0, r1
    bne     .Lnoep0out_clr
    @ Match!  Reset into BOOTSEL.  We let any pending EP0 ZLP IN have
    @ already been sent by the SETUP handler before getting here, so the
    @ host sees a graceful USB tear-down.  rom_reset_to_bootsel does not
    @ return.
    bl      rom_reset_to_bootsel
.Lnoep0out_clr:
    movs    r0, #2
    str     r0, [r4, #USB_BUFF_STATUS]
.Lnoep0out:

    @ EP1 IN (bit 2) - previous bulk transmit completed; clear cdc_in_busy
    @ and try to flush more from TX ring.
    movs    r6, #4
    tst     r5, r6
    beq     .Lnoep1in
    ldr     r0, =cdc_in_busy
    movs    r1, #0
    strb    r1, [r0]
    bl      _cdc_try_flush_tx
    movs    r0, #4
    str     r0, [r4, #USB_BUFF_STATUS]
.Lnoep1in:

    @ EP1 OUT (bit 3) - bulk OUT received; drain into RX ring + re-arm
    movs    r6, #8
    tst     r5, r6
    beq     .Lnoep1out
    bl      _cdc_drain_ep1_out
    movs    r0, #1
    movs    r1, #USB_EP_BULK_MAX_PACKET
    bl      usb_ep_receive_arm
    movs    r0, #8
    str     r0, [r4, #USB_BUFF_STATUS]
.Lnoep1out:

    pop     {r4, r5, r6, r7, pc}

@ ============================================================================
@ Section 4: CDC ring buffers + helpers.
@ ============================================================================

@ ----------------------------------------------------------------------------
@ _cdc_drain_ep1_out - copy received bytes from EP1 OUT buffer into rx ring.
@ Called from BUFF_STATUS handler.
@ ----------------------------------------------------------------------------
    .section .text._cdc_drain_ep1_out, "ax"
    .thumb_func
_cdc_drain_ep1_out:
    push    {r4, r5, r6, r7, lr}
    @ Read length from buf_ctrl OUT
    ldr     r0, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL + 4 + 8     @ ep1 out
    ldr     r0, [r0]
    movw    r1, #0x3FF
    and     r0, r0, r1                            @ r0 = length
    cbz     r0, 99f

    ldr     r4, =USBCTRL_DPRAM_BASE + USB_EP1_OUT_BUF_OFFSET
    ldr     r5, =cdc_rx_buf
    ldr     r6, =cdc_rx_head
    ldr     r7, =cdc_rx_tail
    ldrh    r2, [r6]                              @ head
    ldrh    r3, [r7]                              @ tail
    mov     r1, r0                                @ remaining bytes
1:  @ Free space = (head - tail - 1) & MASK; bail if full
    sub     r0, r2, r3
    subs    r0, #1
    and     r0, #CDC_RING_MASK
    cbz     r0, 9f
    ldrb    r0, [r4], #1
    strb    r0, [r5, r3]
    adds    r3, #1
    and     r3, #CDC_RING_MASK
    subs    r1, #1
    bne     1b
9:  strh    r3, [r7]                              @ tail back
99:
    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ _cdc_try_flush_tx - if EP1 IN is idle, drain up to 64 bytes from TX ring.
@ ----------------------------------------------------------------------------
    .section .text._cdc_try_flush_tx, "ax"
    .thumb_func
    .global _cdc_try_flush_tx
_cdc_try_flush_tx:
    push    {r4, r5, r6, r7, lr}
    ldr     r0, =cdc_in_busy
    ldrb    r1, [r0]
    cbz     r1, 1f
    pop     {r4, r5, r6, r7, pc}                  @ already busy
1:
    ldr     r4, =cdc_tx_buf
    ldr     r5, =cdc_tx_head
    ldr     r6, =cdc_tx_tail
    ldrh    r2, [r5]                              @ head
    ldrh    r3, [r6]                              @ tail
    cmp     r2, r3
    beq     99f                                   @ ring empty - nothing to do

    @ Copy at most 64 bytes from ring at [head..tail) into the EP1 IN buffer.
    ldr     r7, =USBCTRL_DPRAM_BASE + USB_EP1_IN_BUF_OFFSET
    movs    r0, #0                                @ count
2:  cmp     r0, #USB_EP_BULK_MAX_PACKET
    bge     3f
    cmp     r2, r3
    beq     3f
    ldrb    r1, [r4, r2]
    strb    r1, [r7], #1
    adds    r2, #1
    and     r2, #CDC_RING_MASK
    adds    r0, #1
    b       2b
3:
    @ Update head, mark busy, kick the EP via usb_ep_send-style buf_ctrl
    strh    r2, [r5]
    @ buf_ctrl write inline rather than calling usb_ep_send (since we already
    @ copied bytes to the buffer).  Pattern matches usb_ep_send tail.
    ldr     r1, =usb_ep1_in_pid
    ldrb    r2, [r1]
    eors    r2, #1
    strb    r2, [r1]                              @ next PID
    eors    r2, #1                                @ current PID

    ldr     r3, =(USB_BUFCTRL_AVAILABLE_0 | USB_BUFCTRL_FULL_0 | USB_BUFCTRL_LAST_0)
    orrs    r0, r3                                @ len | flags
    cbz     r2, 4f
    ldr     r3, =USB_BUFCTRL_PID_0_DATA1
    orrs    r0, r3
4:
    ldr     r3, =USBCTRL_DPRAM_BASE + USB_DPRAM_EP_BUF_CTRL + 8        @ ep1 in
    str     r0, [r3]

    @ Mark busy
    ldr     r0, =cdc_in_busy
    movs    r1, #1
    strb    r1, [r0]
99:
    pop     {r4, r5, r6, r7, pc}

@ ----------------------------------------------------------------------------
@ cdc_putc(byte) - push to the TX ring; trigger flush if EP idle.
@ ----------------------------------------------------------------------------
    .section .text.cdc_putc, "ax"
    .thumb_func
    .global  cdc_putc
cdc_putc:
    push    {r4, r5, lr}
    ldr     r4, =cdc_tx_head
    ldr     r5, =cdc_tx_tail
    ldrh    r1, [r4]                              @ head
    ldrh    r2, [r5]                              @ tail

    @ Free space = (head - tail - 1) & MASK
    sub     r3, r1, r2
    subs    r3, #1
    and     r3, #CDC_RING_MASK
    cbz     r3, 99f                               @ ring full - drop byte

    ldr     r3, =cdc_tx_buf
    strb    r0, [r3, r2]
    adds    r2, #1
    and     r2, #CDC_RING_MASK
    strh    r2, [r5]                              @ tail back

    bl      _cdc_try_flush_tx
99:
    pop     {r4, r5, pc}

@ ----------------------------------------------------------------------------
@ cdc_puts(str_ptr) - puts NUL-terminated string.
@ ----------------------------------------------------------------------------
    .section .text.cdc_puts, "ax"
    .thumb_func
    .global  cdc_puts
cdc_puts:
    push    {r4, lr}
    mov     r4, r0
1:  ldrb    r0, [r4], #1
    cbz     r0, 9f
    bl      cdc_putc
    b       1b
9:  pop     {r4, pc}

@ ----------------------------------------------------------------------------
@ cdc_available -> r0 - bytes currently in RX ring.
@ ----------------------------------------------------------------------------
    .section .text.cdc_available, "ax"
    .thumb_func
    .global  cdc_available
cdc_available:
    ldr     r1, =cdc_rx_head
    ldr     r2, =cdc_rx_tail
    ldrh    r0, [r2]                              @ tail
    ldrh    r3, [r1]                              @ head
    sub     r0, r0, r3
    and     r0, #CDC_RING_MASK
    bx      lr

@ ----------------------------------------------------------------------------
@ cdc_getc -> r0 - return next byte (0..255), or -1 if empty.
@ ----------------------------------------------------------------------------
    .section .text.cdc_getc, "ax"
    .thumb_func
    .global  cdc_getc
cdc_getc:
    ldr     r1, =cdc_rx_head
    ldr     r2, =cdc_rx_tail
    ldrh    r3, [r1]                              @ head
    ldrh    r0, [r2]                              @ tail
    cmp     r3, r0
    bne     1f
    movs    r0, #0
    mvns    r0, r0                                @ -1
    bx      lr
1:  ldr     r2, =cdc_rx_buf
    ldrb    r0, [r2, r3]
    adds    r3, #1
    and     r3, #CDC_RING_MASK
    strh    r3, [r1]
    bx      lr

@ ============================================================================
@ Static lookup tables / canned responses.
@ ============================================================================

    .section .rodata.usb_misc, "a"
    .align   2
_usb_zero_status:
    .short  0
_usb_line_coding_default:
    @ 7-byte CDC LINE_CODING reply: 115200 baud, 1 stop bit, no parity, 8 data
    .word   115200
    .byte   0          @ stop bits = 1
    .byte   0          @ parity = none
    .byte   8          @ data bits
