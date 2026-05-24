# USB device controller (M4-H)

`src/usb.S` is the ticktrace USB device-mode driver, plus a minimal CDC-ACM
class layer.  Plug a Pico 2 running `usb_cdc_echo_demo.uf2` into a host and
`/dev/ttyACM0` will appear; bytes you send round-trip back as echoes.

This document describes the controller architecture, the DPRAM layout, the
SETUP-handler state machine, the CDC-ACM descriptor walkthrough, and what
to test when you flash a real Pico 2.

## Controller architecture

The RP2350 USB controller is a full-speed (12 Mbps) USB 2.0 IP block with
a built-in PHY.  It exposes two memory windows:

| Base         | Size  | Contents                                   |
| ------------ | ----- | ------------------------------------------ |
| `0x50100000` | 4 KiB | DPRAM: packet buffers + per-EP control     |
| `0x50110000` | 4 KiB | controller registers (CTRL/STATUS/INT)     |

Bring-up order, all in `usb_device_init`:

1.  Clear `RESETS_RESET[28]` (bit `usbctrl`) via the `+0x3000` atomic CLR
    alias.  Spin on `RESET_DONE[28]`.
2.  Zero the entire 4 KiB DPRAM so EP control + buffer-control words start
    in a known state.
3.  `USB_MUXING = TO_PHY | SOFTCON`: route the controller to the internal
    PHY and let firmware control connect/disconnect.
4.  `USB_PWR = VBUS_DETECT | VBUS_DETECT_OVERRIDE_EN`: the Pico 2 doesn't
    have a VBUS sense pin, so we pretend it's always asserted.
5.  `MAIN_CTRL = CTRL_EN` (device mode; `HOST_NDEVICE = 0`).
6.  `SIE_CTRL = PULLUP_EN | EP0_INT_1BUF`: signal the device's presence on
    the bus and enable EP0 buffer-completion interrupts.
7.  `INTE = SETUP_REQ | BUFF_STATUS | BUS_RESET`: only the three IRQ lines
    we care about.

After step 7 the host sees the device on the bus and starts enumerating.

## DPRAM layout

```
0x000  setup_packet[8]              SETUP request (host -> device)
0x008  ep_ctrl[1..15] in/out        15 pairs * 8 = 120 B
                                    offset = 0x08 + 8*(n-1)
                                    EP0 has no ep_ctrl entry (implicit).
0x080  ep_buf_ctrl[0..15] in/out    16 pairs * 8 = 128 B
                                    offset = 0x80 + 8*n
0x100  ep0 buffer 0 (64 B)          shared by EP0 IN and OUT
0x140  ep0 buffer 1 (64 B)          double-buffer slot (unused)
0x180  ep1 OUT buffer (64 B)        bulk RX (CDC data interface)
0x1C0  ep1 IN buffer (64 B)         bulk TX (CDC data interface)
0x200  ep2 IN buffer (8 B)          interrupt notification (CDC control)
0x208  free
```

### ep_ctrl word

```
[31]    ENABLE
[30]    DOUBLE_BUFFERED
[29]    INT_ON_NAK
[28]    INT_ON_STALL
[27:26] ENDPOINT_TYPE  (0=control / 1=iso / 2=bulk / 3=interrupt)
[15:0]  BUFFER_ADDRESS (DPRAM offset, 64-byte aligned)
```

Bulk EP1 IN, for example: `ENABLE | (BULK<<26) | 0x1C0 = 0x880001C0`.

### ep_buf_ctrl word (low half, buffer 0)

```
[26]    FULL        for IN: HW clears after sending; for OUT: HW sets on RX
[25:16] LENGTH_1    (we don't use double-buffering)
[15]    LAST_0      "this is the last buffer of the transfer"
[14:13] PID_0       0=DATA0, 1=DATA1
[12]    RESET       reset PID toggle to DATA0
[11]    STALL
[10]    AVAILABLE_0 1 = controller may use buffer 0
[9:0]   LENGTH_0    bytes (IN: how many to send; OUT: how many host sent)
```

To ship 5 bytes on EP0 IN with PID DATA1:
`AVAILABLE | FULL | LAST | (1<<13) | 5 = 0x0400_E405`.

## SETUP-handler state machine

![USB SETUP state machine: BUS_RESET enters the reset state (ADDR=0); SETUP_REQ transitions into the 8-byte SETUP parser, which fans out into five branches — GET_DESCR (table lookup + EP0 IN copy), SET_ADDR (pending write applied on next BUFF_STAT), SET_CFG (ep_ctrl setup + EP1 OUT arm), CDC_REQ (ZLP or 7-byte canned reply), or STALL (EP_STALL_ARM + buf_ctrl.STALL=1)](images/usb-setup-state.svg)

Key invariants:

* **Toggle latency on SET_ADDRESS.**  USB spec says host issues
  `SET_ADDRESS(N)` and the device must finish the status stage at *address
  zero*, then start using `N`.  We latch `N` into `usb_pending_address`
  and the BUFF_STATUS handler applies it after the EP0 IN ZLP completes.
* **EP0 PID reset.**  A control transfer's first IN data packet always
  uses DATA1.  At each SETUP entry we reset `usb_ep0_pid = 1` so the next
  `usb_ep_send` picks DATA1 and toggles to DATA0 for the second packet.
* **Status-stage arming.**  After replying to `GET_DESCRIPTOR` we re-arm
  EP0 OUT with `len = 0` so the host's status ZLP is consumed.

## CDC-ACM descriptor walkthrough

The host enumerates a CDC-ACM device by reading these descriptors in order:

1.  **Device descriptor** (18 B): VID 0x2E8A, PID 0x10EE, class = MISC
    (0xEF / 02 / 01) so the IAD subclass kicks in and the host knows to
    look at the interface descriptors for the actual class.
2.  **Configuration descriptor bundle** (67 B): header + interface +
    CDC functional descriptors + endpoints.  Two interfaces:

    | iface | class      | subclass | endpoint    | purpose                 |
    | ----- | ---------- | -------- | ----------- | ----------------------- |
    | 0     | CDC (0x02) | ACM (2)  | EP2 IN int  | notifications (unused)  |
    | 1     | CDC-DATA   | -        | EP1 IN/OUT  | bulk data (host <-> dev)|

    The CDC functional descriptors (header / call-mgmt / ACM / union) sit
    *after* interface 0 and *before* its endpoint descriptor.  Their order
    matters: `lsusb -v` rejects bundles that reorder them.

3.  **String descriptors**: language id 0x0409, manufacturer "ticktrace",
    product "ticktrace CDC", serial "000000000001".

After the host issues `SET_CONFIGURATION 1` the firmware:

1.  Writes ep_ctrl[1].in / ep_ctrl[1].out / ep_ctrl[2].in to enable the
    bulk and interrupt endpoints.
2.  Arms EP1 OUT for a 64-byte transfer (so the first host-typed byte
    can land).
3.  Replies with a ZLP on EP0 IN (status stage of `SET_CONFIGURATION`).

`/dev/ttyACM0` appears on the host once steady-state enumeration finishes.

## Cycle budgets (real silicon, 150 MHz clk_sys)

| function                                     | cycles            |
| -------------------------------------------- | ----------------- |
| `usb_device_init`                            | ~80 + reset settle|
| `usb_ep_send` small payload (N bytes)        | ~30 + 4N          |
| `usb_ep_receive_arm`                         | ~14               |
| ISR fast path (BUFF_STATUS, EP1 OUT drain)   | ~60               |
| ISR SETUP path (GET_DESCRIPTOR Device)       | ~80               |
| ISR SETUP path (SET_ADDRESS)                 | ~30               |
| `cdc_putc` ring push (no flush)              | ~20               |

## What to test on a real Pico 2

1.  Build and flash.  Either variant works on hardware now (see
    `docs/boot.md`); the flash variant is recommended for anything
    you want to survive a power cycle:

    ```
    make build/usb_cdc_echo_demo_flash.uf2
    # hold BOOTSEL while plugging in USB
    cp build/usb_cdc_echo_demo_flash.uf2 /run/media/$USER/RP2350/
    ```

2.  Within ~1 s, `dmesg` on a Linux host should show:

    ```
    usb 1-1.4: new full-speed USB device number 12 using xhci_hcd
    usb 1-1.4: New USB device found, idVendor=2e8a, idProduct=10ee
    usb 1-1.4: Product: ticktrace CDC
    usb 1-1.4: Manufacturer: ticktrace
    cdc_acm 1-1.4:1.0: ttyACM0: USB ACM device
    ```

3.  Open the port and exercise the echo:

    ```
    stty -F /dev/ttyACM0 raw -echo
    cat /dev/ttyACM0 &
    echo "hello, ticktrace!" > /dev/ttyACM0
    ```

    Expect "hello, ticktrace!" to print on the terminal.

### Fallback: descriptor-only

If the CDC echo path is misbehaving, flash `usb_descriptor_only_demo_flash.uf2`
instead.  It runs the same `usb_device_init` and SETUP plumbing -- so it
also enumerates as a CDC device and `ttyACM0` will appear -- but its
main loop is just `wfi`.  No bytes flow on EP1, so reads/writes against
`/dev/ttyACM0` will time out without echoing.

This separates "is enumeration alive?" (descriptor-only enumerates =>
controller + PHY + SETUP + bulk-EP descriptors are all correct) from
"is the bulk data path working?" (only the CDC echo demo actually
exercises EP1 OUT/IN traffic).

## What's supported

* Device mode, full-speed (12 Mbps).
* EP0 control transfers, including **multi-packet IN** for descriptors
  larger than the 64-byte EP0 max packet size.  The CDC config bundle
  is 67 bytes; `_usb_ep0_start_tx` saves state in `usb_ep0_tx_{src,
  remaining}` and ships chunks on each EP0 IN BUFF_STATUS until the
  whole transfer is delivered.
* Independent EP0 IN/OUT PID toggles (`usb_ep0_pid` / `usb_ep0_out_pid`).
* EP1 bulk IN + OUT, EP2 interrupt IN, all with `INTERRUPT_PER_BUFF`
  set so buffer completions raise the USB IRQ.
* CDC-ACM class on EP1 (data) + EP2 (notification).

## What's deliberately NOT supported in v0.1

* Host mode (only device).
* Isochronous endpoints.
* Multiple configurations or alternate settings.
* Remote wake / suspend / LPM.
* Double-buffered endpoints.
* CDC AT commands (we report `bInterfaceProtocol = 0`).
* Real `SET_LINE_CODING` honouring (we ack and discard).
* ZLP-after-MPS-multiple at end of IN transfer (our descriptors aren't
  multiples of 64, so the short final packet implicitly terminates).

Everything above is reachable from the same controller registers; the
v0.2 milestone is a good place to add isoc audio or a HID composite
device, both of which reuse `usb_ep_send` / `usb_ep_receive_arm`.
