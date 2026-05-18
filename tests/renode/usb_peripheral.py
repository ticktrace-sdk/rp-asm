# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""Reference USB peripheral source for tests/renode/rp2350.repl (M4-H).

Renode's PythonPeripheral inlines its script directly in the .repl file, so
this Python module is mostly documentation: it captures the canonical
bit-level behaviour the firmware sees, and the inline copy in rp2350.repl
must stay in sync.

The model is permissive on purpose:

  * Every register read returns 0 unless we have a more useful default
    (e.g. SIE_STATUS reflects whether SETUP / BUS_RESET have been pre-pended).
  * Writes are logged but produce no side effects beyond storing the value
    so the firmware's read-after-write paths see what they wrote.
  * MAIN_CTRL writes log "USB_MAIN_CTRL <- 0xNNNN" so the .resc assertion
    can grep for `USB_MAIN_CTRL <-` to confirm the controller-enable store
    landed.
  * USB_BUFF_STATUS writes (W1C from the firmware's POV) are logged.

What is NOT modelled:

  * SETUP packet delivery (we don't drive the device through a host)
  * Endpoint completion (no BUFF_STATUS bits flip on their own)
  * PHY behaviour, line state, or VBUS detection beyond the override

For the M4-H smoke test that's enough: the firmware brings up the
controller, configures the PHY, sets MAIN_CTRL, and goes to wfi.  The .resc
asserts on the CONTROLLER_EN store; everything past it is "real silicon
only" territory.
"""

# The script body below is the canonical version of the inlined script in
# rp2350.repl.  Paste any change here into the .repl as well.

USB_PERIPHERAL_SCRIPT = r'''
if request.IsInit:
    state = {
        'main_ctrl':   0,
        'sie_ctrl':    0,
        'sie_status':  0,
        'buff_status': 0,
        'inte':        0,
        'intr':        0,
        'addr_endp':   0,
        'usb_muxing':  0,
        'usb_pwr':     0,
    }
elif request.IsRead:
    off = request.Offset & 0xFFFF
    if   off == 0x000: request.Value = state['addr_endp']
    elif off == 0x040: request.Value = state['main_ctrl']
    elif off == 0x04C: request.Value = state['sie_ctrl']
    elif off == 0x050: request.Value = state['sie_status']
    elif off == 0x058: request.Value = state['buff_status']
    elif off == 0x074: request.Value = state['usb_muxing']
    elif off == 0x078: request.Value = state['usb_pwr']
    elif off == 0x08C: request.Value = state['intr']
    elif off == 0x090: request.Value = state['inte']
    elif off == 0x098: request.Value = state['intr'] & state['inte']
    else:              request.Value = 0
elif request.IsWrite:
    off = request.Offset & 0xFFFF
    val = request.Value & 0xFFFFFFFF
    if   off == 0x000:
        state['addr_endp'] = val
        self.Log(LogLevel.Info, 'USB_ADDR_ENDP <- 0x{0:08X}'.format(val))
    elif off == 0x040:
        state['main_ctrl'] = val
        self.Log(LogLevel.Info, 'USB_MAIN_CTRL <- 0x{0:08X}'.format(val))
    elif off == 0x04C:
        state['sie_ctrl'] = val
    elif off == 0x050:
        # SIE_STATUS bits are W1C - just clear what was written.
        state['sie_status'] = state['sie_status'] & ((~val) & 0xFFFFFFFF)
    elif off == 0x058:
        # BUFF_STATUS is also W1C.
        state['buff_status'] = state['buff_status'] & ((~val) & 0xFFFFFFFF)
    elif off == 0x074:
        state['usb_muxing'] = val
    elif off == 0x078:
        state['usb_pwr'] = val
    elif off == 0x08C:
        # INTR is W1C in this register.
        state['intr'] = state['intr'] & ((~val) & 0xFFFFFFFF)
    elif off == 0x090:
        state['inte'] = val
'''
