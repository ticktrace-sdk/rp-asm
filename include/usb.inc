@ =============================================================================
@ usb.inc - RP2350 USB controller register / bitfield definitions (M4-H).
@
@ Datasheet ref: RP2350 datasheet rev 0.3 (Aug 2024) sec 13 (USB controller).
@                The RP2350 USB block is bug-for-bug compatible with the RP2040
@                USB controller; the RP2040 datasheet sec 4.1 is the canonical
@                reference for the DPRAM layout, which the RP2350 inherits.
@
@ Two BARs:
@   USBCTRL_DPRAM_BASE = 0x50100000   4 KiB dual-port RAM (host-visible buffers
@                                     + per-EP control words + SETUP packet)
@   USBCTRL_REGS_BASE  = 0x50110000   controller registers (CTRL/STATUS/INT)
@
@ DPRAM layout (4 KiB):
@   0x000  setup_packet[8]              SETUP request (host -> device)
@   0x008  ep_ctrl[1..15] in/out        15 pairs * 8 = 120 B; offset = 0x08 + 8*(n-1)
@                                       Each is { in_control(4), out_control(4) }.
@                                       EP0 has no ep_ctrl entry (it's implicit).
@   0x080  ep_buf_ctrl[0..15] in/out    16 pairs * 8 = 128 B; offset = 0x80 + 8*n
@                                       Per-buffer: AVAILABLE/LENGTH/PID/STALL/...
@   0x100  ep0 buffer 0 (64 B)          shared by EP0 IN and OUT (controller toggles
@                                       direction based on the SETUP request).
@   0x140  ep0 buffer 1 (64 B)          double-buffer slot (we don't use it for
@                                       EP0; we always use single-buffer mode).
@   0x180  start of free DPRAM for EP1+ buffers
@
@ Each ep_ctrl word (32 bits):
@   [29:0]   BUFFER_ADDRESS     offset within DPRAM of this EP's data buffer
@                               (must be 64-byte aligned; written as a DPRAM
@                               offset, not an absolute bus address)
@   [27:26]  ENDPOINT_TYPE      0=control, 1=isochronous, 2=bulk, 3=interrupt
@   [29]     INTERRUPT_ON_NAK
@   [28]     INTERRUPT_ON_STALL
@   [30]     DOUBLE_BUFFERED
@   [31]     ENABLE
@
@ Each ep_buf_ctrl word (32 bits) - per buffer:
@   [9:0]    LENGTH_0           bytes in buffer 0 (or to send for IN)
@   [10]     AVAILABLE_0        1 = controller may use buffer 0
@   [11]     STALL              1 = stall this endpoint
@   [12]     RESET              1 = reset PID to DATA0
@   [14:13]  PID_0              0=DATA0, 1=DATA1
@   [15]     LAST_0             1 = this is the last buffer of the transfer
@   [25:16]  LENGTH_1           bytes in buffer 1
@   [26]     FULL_0             RW; for OUT 1=buffer has data; for IN cleared
@                               by HW after the buffer is sent
@   [27]     FULL_1
@   [28]     LAST_1
@   [30:29]  PID_1
@   [31]     AVAILABLE_1
@
@ Note: bit assignments above are simplified; the full layout is in the
@ datasheet.  We only manipulate the LOW half (LENGTH_0 / AVAILABLE_0 / FULL_0
@ / PID_0 / LAST_0) since v0.1 uses single buffers exclusively.
@ =============================================================================

@ ----- Bases -----------------------------------------------------------------
    .equ USBCTRL_DPRAM_BASE,     0x50100000
    .equ USBCTRL_REGS_BASE,      0x50110000

@ ----- DPRAM offsets ---------------------------------------------------------
    .equ USB_DPRAM_SETUP_PACKET, 0x000
    .equ USB_DPRAM_EP_CTRL_BASE, 0x008    @ ep_ctrl[1].in
    .equ USB_DPRAM_EP_BUF_CTRL,  0x080    @ ep_buf_ctrl[0].in
    .equ USB_DPRAM_EP0_BUF0,     0x100
    .equ USB_DPRAM_EP0_BUF1,     0x140
    .equ USB_DPRAM_DATA_BUFS,    0x180    @ start of free pool for EP1+

@   ep_ctrl[n].in   @ EP_CTRL_BASE + 8*(n-1)        for n = 1..15
@   ep_ctrl[n].out  @ EP_CTRL_BASE + 8*(n-1) + 4
@   ep_buf_ctrl[n].in   @ EP_BUF_CTRL + 8*n         for n = 0..15
@   ep_buf_ctrl[n].out  @ EP_BUF_CTRL + 8*n + 4

@ ----- ep_ctrl word bits ----------------------------------------------------
    .equ USB_EPCTRL_ENABLE,           (1 << 31)
    .equ USB_EPCTRL_DOUBLE_BUFFERED,  (1 << 30)
    .equ USB_EPCTRL_INT_ON_NAK,       (1 << 29)
    .equ USB_EPCTRL_INT_ON_STALL,     (1 << 28)
    .equ USB_EPCTRL_INTERRUPT_PER_BUF,(1 << 29)   @ alias name in some docs
    .equ USB_EPCTRL_TYPE_LSB,         26
    .equ USB_EPCTRL_TYPE_CONTROL,     (0 << 26)
    .equ USB_EPCTRL_TYPE_ISO,         (1 << 26)
    .equ USB_EPCTRL_TYPE_BULK,        (2 << 26)
    .equ USB_EPCTRL_TYPE_INTERRUPT,   (3 << 26)

@ ----- ep_buf_ctrl word bits (low half - buffer 0) --------------------------
    .equ USB_BUFCTRL_AVAILABLE_0,     (1 << 10)
    .equ USB_BUFCTRL_STALL,           (1 << 11)
    .equ USB_BUFCTRL_RESET,           (1 << 12)
    .equ USB_BUFCTRL_PID_0_LSB,       13
    .equ USB_BUFCTRL_PID_0_DATA0,     (0 << 13)
    .equ USB_BUFCTRL_PID_0_DATA1,     (1 << 13)
    .equ USB_BUFCTRL_LAST_0,          (1 << 15)
    .equ USB_BUFCTRL_FULL_0,          (1 << 26)
    @ LENGTH_0 occupies bits [9:0]; mask = 0x3FF

@ ----- Controller registers (relative to USBCTRL_REGS_BASE) -----------------
    .equ USB_ADDR_ENDP,           0x000     @ device address + EP0 endpoint
    .equ USB_ADDR_ENDP1,          0x004     @ host-mode only on EP1..15
    @  ... 0x008 .. 0x03C for ADDR_ENDP2..15 (host-mode)
    .equ USB_MAIN_CTRL,           0x040
    .equ USB_SOF_WR,              0x044
    .equ USB_SOF_RD,              0x048
    .equ USB_SIE_CTRL,            0x04C
    .equ USB_SIE_STATUS,          0x050
    .equ USB_INT_EP_CTRL,         0x054
    .equ USB_BUFF_STATUS,         0x058
    .equ USB_BUFF_CPU_SHOULD_HANDLE, 0x05C
    .equ USB_EP_ABORT,            0x060
    .equ USB_EP_ABORT_DONE,       0x064
    .equ USB_EP_STALL_ARM,        0x068
    .equ USB_NAK_POLL,            0x06C
    .equ USB_EP_STATUS_STALL_NAK, 0x070
    .equ USB_USB_MUXING,          0x074
    .equ USB_USB_PWR,             0x078
    .equ USB_USBPHY_DIRECT,       0x07C
    .equ USB_USBPHY_DIRECT_OVERRIDE, 0x080
    .equ USB_USBPHY_TRIM,         0x084
    .equ USB_INTR,                0x08C
    .equ USB_INTE,                0x090
    .equ USB_INTF,                0x094
    .equ USB_INTS,                0x098

@ ----- MAIN_CTRL bits --------------------------------------------------------
    .equ USB_MAIN_CTRL_CTRL_EN,       (1 << 0)
    .equ USB_MAIN_CTRL_HOST_NDEVICE,  (1 << 1)
    .equ USB_MAIN_CTRL_SIM_TIMING,    (1 << 31)

@ ----- SIE_CTRL bits (subset) -----------------------------------------------
    .equ USB_SIE_CTRL_PULLUP_EN,      (1 << 16)   @ device-mode pull-up
    .equ USB_SIE_CTRL_EP0_INT_NAK,    (1 << 27)
    .equ USB_SIE_CTRL_EP0_INT_2BUF,   (1 << 28)
    .equ USB_SIE_CTRL_EP0_INT_1BUF,   (1 << 29)
    .equ USB_SIE_CTRL_EP0_DOUBLE_BUF, (1 << 30)
    .equ USB_SIE_CTRL_EP0_INT_STALL,  (1 << 31)

@ ----- SIE_STATUS bits ------------------------------------------------------
    .equ USB_SIE_STATUS_VBUS_DETECTED,  (1 << 17)
    .equ USB_SIE_STATUS_LINE_STATE_LSB, 22
    .equ USB_SIE_STATUS_SUSPENDED,      (1 << 4)
    .equ USB_SIE_STATUS_SPEED_LSB,      8
    .equ USB_SIE_STATUS_BUS_RESET,      (1 << 19)    @ W1C
    .equ USB_SIE_STATUS_TRANS_COMPLETE, (1 << 18)    @ W1C - control xfer done
    .equ USB_SIE_STATUS_SETUP_REC,      (1 << 17)    @ W1C - SETUP packet recvd
                                                     @ NB: same bit as VBUS_DETECTED
                                                     @ in some docs; we treat 17
                                                     @ as SETUP_REC per RP2040 ref

@ Cleaner names for the bits we W1C in the ISR (using the canonical RP2040
@ datasheet bit positions for SIE_STATUS):
    .equ USB_SIE_STATUS_W_BUS_RESET,    (1 << 19)
    .equ USB_SIE_STATUS_W_TRANS_COMPLETE,(1 << 18)
    .equ USB_SIE_STATUS_W_SETUP_REC,    (1 << 17)
    .equ USB_SIE_STATUS_W_RESUME,       (1 << 11)

@ ----- USB_MUXING bits -------------------------------------------------------
    .equ USB_MUXING_TO_PHY,           (1 << 0)
    .equ USB_MUXING_TO_EXTPHY,        (1 << 1)
    .equ USB_MUXING_TO_DIGITAL_PAD,   (1 << 2)
    .equ USB_MUXING_SOFTCON,          (1 << 3)

@ ----- USB_PWR bits ----------------------------------------------------------
    .equ USB_PWR_VBUS_EN,                 (1 << 0)
    .equ USB_PWR_VBUS_EN_OVERRIDE_EN,     (1 << 1)
    .equ USB_PWR_VBUS_DETECT,             (1 << 2)
    .equ USB_PWR_VBUS_DETECT_OVERRIDE_EN, (1 << 3)
    .equ USB_PWR_OVERCURR_DETECT,         (1 << 4)
    .equ USB_PWR_OVERCURR_DETECT_EN,      (1 << 5)

@ ----- INTR / INTE / INTS bits ----------------------------------------------
    .equ USB_INT_HOST_CONN_DIS,       (1 << 0)
    .equ USB_INT_HOST_RESUME,         (1 << 1)
    .equ USB_INT_HOST_SOF,            (1 << 2)
    .equ USB_INT_TRANS_COMPLETE,      (1 << 3)
    .equ USB_INT_BUFF_STATUS,         (1 << 4)
    .equ USB_INT_ERROR_DATA_SEQ,      (1 << 5)
    .equ USB_INT_ERROR_RX_TIMEOUT,    (1 << 6)
    .equ USB_INT_ERROR_RX_OVERFLOW,   (1 << 7)
    .equ USB_INT_ERROR_BIT_STUFF,     (1 << 8)
    .equ USB_INT_ERROR_CRC,           (1 << 9)
    .equ USB_INT_STALL,               (1 << 10)
    .equ USB_INT_VBUS_DETECT,         (1 << 11)
    .equ USB_INT_BUS_RESET,           (1 << 12)
    .equ USB_INT_DEV_CONN_DIS,        (1 << 13)
    .equ USB_INT_DEV_SUSPEND,         (1 << 14)
    .equ USB_INT_DEV_RESUME_FROM_HOST,(1 << 15)
    .equ USB_INT_SETUP_REQ,           (1 << 16)
    .equ USB_INT_DEV_SOF,             (1 << 17)
    .equ USB_INT_ABORT_DONE,          (1 << 18)
    .equ USB_INT_EP_STALL_NAK,        (1 << 19)

@ ----- ADDR_ENDP -------------------------------------------------------------
    .equ USB_ADDR_ENDP_ADDRESS_LSB,   0
    .equ USB_ADDR_ENDP_ADDRESS_MASK,  0x7F
    .equ USB_ADDR_ENDP_ENDPOINT_LSB,  16
    .equ USB_ADDR_ENDP_ENDPOINT_MASK, (0xF << 16)

@ ----- RESETS bit ------------------------------------------------------------
    .equ RESETS_usbctrl,              28

@ ----- NVIC IRQ number -------------------------------------------------------
@   RP2350 datasheet sec 3.2: USBCTRL_IRQ = 14
    .equ USBCTRL_IRQ,                 14

@ ----- Bulk EP buffer constants ----------------------------------------------
@   We use a single 64-byte buffer per direction for EP0 (control) and EP1
@   (CDC bulk).  EP2 is the CDC notification interrupt EP - we never actually
@   send notifications, but we still allocate the descriptor for completeness.
    .equ USB_EP0_MAX_PACKET,          64
    .equ USB_EP_BULK_MAX_PACKET,      64
    .equ USB_EP_INT_MAX_PACKET,       8

@ DPRAM offset of the EP1 (bulk OUT and IN) buffer.  We place EP1 OUT at
@ 0x180 and EP1 IN at 0x1C0; EP2 IN (interrupt notification) at 0x200.
    .equ USB_EP1_OUT_BUF_OFFSET,      0x180
    .equ USB_EP1_IN_BUF_OFFSET,       0x1C0
    .equ USB_EP2_IN_BUF_OFFSET,       0x200
