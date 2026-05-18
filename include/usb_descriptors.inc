@ SPDX-License-Identifier: AGPL-3.0-or-later
@
@ Copyright (C) 2026 Amken LLC <https://www.amken.us>
@
@ This file is part of the ticktrace Assembly SDK.
@ Licensed under AGPL-3.0-or-later; commercial license available.
@ See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

@ =============================================================================
@ usb_descriptors.inc - USB standard constants + pre-baked descriptor blobs
@                       for the ticktrace M4-H CDC-ACM device.
@
@ References:
@   - USB 2.0 Specification, chapter 9 (standard requests + descriptor types)
@   - USB CDC 1.2 Specification + PSTN sub-class spec (CDC-ACM)
@   - USB Class Definitions for Communications Devices 1.2
@
@ The .byte sequences below are emitted via .byte/.short little-endian; they
@ will be linked into .rodata and copied to DPRAM by the SETUP handler.
@
@ Layout summary:
@   usb_device_descriptor          18 B
@   usb_configuration_descriptor   67 B (config + 2 interface assoc + interfaces +
@                                       CDC functional descriptors + 3 endpoints)
@   usb_string_lang                4 B  (string id 0; LANGID = 0x0409 en-US)
@   usb_string_manufacturer        20 B
@   usb_string_product             24 B
@   usb_string_serial              22 B
@ =============================================================================

@ ---- Standard request types (bRequest) -------------------------------------
    .equ USB_REQ_GET_STATUS,          0
    .equ USB_REQ_CLEAR_FEATURE,       1
    .equ USB_REQ_SET_FEATURE,         3
    .equ USB_REQ_SET_ADDRESS,         5
    .equ USB_REQ_GET_DESCRIPTOR,      6
    .equ USB_REQ_SET_DESCRIPTOR,      7
    .equ USB_REQ_GET_CONFIGURATION,   8
    .equ USB_REQ_SET_CONFIGURATION,   9
    .equ USB_REQ_GET_INTERFACE,       10
    .equ USB_REQ_SET_INTERFACE,       11

@ ---- bmRequestType direction / type / recipient ----------------------------
    .equ USB_DIR_OUT,                 0x00       @ host -> device
    .equ USB_DIR_IN,                  0x80       @ device -> host
    .equ USB_TYPE_STANDARD,           0x00
    .equ USB_TYPE_CLASS,              0x20
    .equ USB_TYPE_VENDOR,             0x40
    .equ USB_RECIP_DEVICE,            0x00
    .equ USB_RECIP_INTERFACE,         0x01
    .equ USB_RECIP_ENDPOINT,          0x02

@ ---- Descriptor types (high byte of wValue in GET_DESCRIPTOR) --------------
    .equ USB_DESC_DEVICE,             1
    .equ USB_DESC_CONFIG,             2
    .equ USB_DESC_STRING,             3
    .equ USB_DESC_INTERFACE,          4
    .equ USB_DESC_ENDPOINT,           5
    .equ USB_DESC_DEVICE_QUALIFIER,   6
    .equ USB_DESC_OTHER_SPEED_CONFIG, 7
    .equ USB_DESC_INTERFACE_POWER,    8
    .equ USB_DESC_INTERFACE_ASSOC,    11

@ ---- USB device class codes -------------------------------------------------
    .equ USB_CLASS_PER_INTERFACE,     0x00
    .equ USB_CLASS_CDC,               0x02
    .equ USB_CLASS_HID,               0x03
    .equ USB_CLASS_VENDOR,            0xFF
    .equ USB_CLASS_CDC_DATA,          0x0A
    .equ USB_CLASS_MISC,              0xEF

@ ---- CDC-specific subclass / protocol codes --------------------------------
    .equ USB_CDC_SUBCLASS_ACM,        0x02
    .equ USB_CDC_PROTOCOL_AT,         0x01
    .equ USB_CDC_PROTOCOL_NONE,       0x00

@ ---- CDC functional descriptor subtypes ------------------------------------
    .equ USB_CDC_TYPE_HEADER,         0x00
    .equ USB_CDC_TYPE_CALL_MGMT,      0x01
    .equ USB_CDC_TYPE_ACM,            0x02
    .equ USB_CDC_TYPE_UNION,          0x06

@ ---- CDC class-specific requests (handled in our SETUP handler) ------------
    .equ USB_CDC_REQ_SET_LINE_CODING,        0x20
    .equ USB_CDC_REQ_GET_LINE_CODING,        0x21
    .equ USB_CDC_REQ_SET_CONTROL_LINE_STATE, 0x22

@ ---- Vendor / product identifiers -------------------------------------------
@   VID 0x2E8A is Raspberry Pi; PID 0x000A is the unallocated test PID we
@   use across all ticktrace CDC examples.  Hosts will see a unique enumeration
@   based on these.
    .equ USB_VID,                     0x2E8A     @ Raspberry Pi (Trading) Ltd
    .equ USB_PID,                     0x10EE     @ Amken's allotted PID
    .equ USB_BCD_DEVICE,              0x0001

@ ---- Descriptor sizes (used in headers + total config length) --------------
    .equ USB_DESC_LEN_DEVICE,         18
    .equ USB_DESC_LEN_CONFIG,         9
    .equ USB_DESC_LEN_INTERFACE,      9
    .equ USB_DESC_LEN_ENDPOINT,       7
    .equ USB_DESC_LEN_CDC_HEADER,     5
    .equ USB_DESC_LEN_CDC_CALLMGMT,   5
    .equ USB_DESC_LEN_CDC_ACM,        4
    .equ USB_DESC_LEN_CDC_UNION,      5

@ Total length of the entire CDC config:  9 + 9 + 5 + 5 + 4 + 5 + 7 + 9 + 7 + 7
@                                       = 67 bytes
    .equ USB_CONFIG_TOTAL_LEN,        67

@ ============================================================================
@ Descriptor blobs - placed in .rodata.usb_descriptors so the linker can pack
@ them adjacent to the rest of the rodata.  Loaders / the SETUP handler take
@ the address of these labels to find the right blob.
@ ============================================================================

    .section .rodata.usb_descriptors, "a"
    .align   2

@ ---- Device descriptor (18 bytes) ------------------------------------------
    .global usb_device_descriptor
    .global usb_device_descriptor_end
usb_device_descriptor:
    .byte   USB_DESC_LEN_DEVICE        @ bLength
    .byte   USB_DESC_DEVICE            @ bDescriptorType
    .short  0x0200                     @ bcdUSB = 2.00
    @ Single-function CDC-ACM: declare CDC at the device level so the host
    @ doesn't expect an Interface Association Descriptor (IAD).  We were
    @ previously setting MISC/0x02/0x01 (the IAD signaling triple) without
    @ actually emitting an IAD in the config, which caused Linux to retry
    @ enumeration with several-second backoff (~5s end-to-end).
    .byte   USB_CLASS_CDC              @ bDeviceClass = CDC (0x02)
    .byte   USB_CDC_SUBCLASS_ACM       @ bDeviceSubClass = ACM (0x02)
    .byte   USB_CDC_PROTOCOL_NONE      @ bDeviceProtocol = none (0x00)
    .byte   USB_EP0_MAX_PACKET         @ bMaxPacketSize0 = 64
    .short  USB_VID                    @ idVendor
    .short  USB_PID                    @ idProduct
    .short  USB_BCD_DEVICE             @ bcdDevice
    .byte   1                          @ iManufacturer (string idx 1)
    .byte   2                          @ iProduct (string idx 2)
    .byte   3                          @ iSerialNumber (string idx 3)
    .byte   1                          @ bNumConfigurations
usb_device_descriptor_end:

@ ---- Configuration descriptor (full bundle, 67 bytes) ----------------------
    .global usb_config_descriptor
    .global usb_config_descriptor_end
usb_config_descriptor:
    @ ---- Configuration header (9 bytes) ------------------------------------
    .byte   USB_DESC_LEN_CONFIG        @ bLength
    .byte   USB_DESC_CONFIG            @ bDescriptorType
    .short  USB_CONFIG_TOTAL_LEN       @ wTotalLength
    .byte   2                          @ bNumInterfaces (CDC control + data)
    .byte   1                          @ bConfigurationValue
    .byte   0                          @ iConfiguration
    .byte   0xC0                       @ bmAttributes = self-powered, no remote wake
    .byte   50                         @ bMaxPower in 2 mA units = 100 mA

    @ ---- Interface 0: CDC control (notification) ---------------------------
    .byte   USB_DESC_LEN_INTERFACE     @ bLength
    .byte   USB_DESC_INTERFACE         @ bDescriptorType
    .byte   0                          @ bInterfaceNumber
    .byte   0                          @ bAlternateSetting
    .byte   1                          @ bNumEndpoints
    .byte   USB_CLASS_CDC              @ bInterfaceClass
    .byte   USB_CDC_SUBCLASS_ACM       @ bInterfaceSubClass
    .byte   USB_CDC_PROTOCOL_NONE      @ bInterfaceProtocol (no AT cmds)
    .byte   0                          @ iInterface

    @ ---- CDC Header functional descriptor ----------------------------------
    .byte   USB_DESC_LEN_CDC_HEADER    @ bLength = 5
    .byte   0x24                       @ bDescriptorType = CS_INTERFACE
    .byte   USB_CDC_TYPE_HEADER        @ bDescriptorSubtype
    .short  0x0110                     @ bcdCDC = 1.10

    @ ---- CDC Call Management functional descriptor -------------------------
    .byte   USB_DESC_LEN_CDC_CALLMGMT  @ bLength = 5
    .byte   0x24                       @ bDescriptorType = CS_INTERFACE
    .byte   USB_CDC_TYPE_CALL_MGMT     @ bDescriptorSubtype
    .byte   0x00                       @ bmCapabilities (no call mgmt)
    .byte   1                          @ bDataInterface

    @ ---- CDC ACM functional descriptor -------------------------------------
    .byte   USB_DESC_LEN_CDC_ACM       @ bLength = 4
    .byte   0x24                       @ bDescriptorType = CS_INTERFACE
    .byte   USB_CDC_TYPE_ACM           @ bDescriptorSubtype
    .byte   0x02                       @ bmCapabilities = SET_LINE_CODING etc.

    @ ---- CDC Union functional descriptor -----------------------------------
    .byte   USB_DESC_LEN_CDC_UNION     @ bLength = 5
    .byte   0x24                       @ bDescriptorType = CS_INTERFACE
    .byte   USB_CDC_TYPE_UNION         @ bDescriptorSubtype
    .byte   0                          @ bMasterInterface = 0
    .byte   1                          @ bSlaveInterface0  = 1

    @ ---- Endpoint 2 IN (notification, interrupt) ---------------------------
    .byte   USB_DESC_LEN_ENDPOINT      @ bLength
    .byte   USB_DESC_ENDPOINT          @ bDescriptorType
    .byte   0x82                       @ bEndpointAddress = EP2 IN
    .byte   0x03                       @ bmAttributes = interrupt
    .short  USB_EP_INT_MAX_PACKET      @ wMaxPacketSize = 8
    .byte   16                         @ bInterval = 16 ms

    @ ---- Interface 1: CDC data --------------------------------------------
    .byte   USB_DESC_LEN_INTERFACE     @ bLength
    .byte   USB_DESC_INTERFACE         @ bDescriptorType
    .byte   1                          @ bInterfaceNumber
    .byte   0                          @ bAlternateSetting
    .byte   2                          @ bNumEndpoints
    .byte   USB_CLASS_CDC_DATA         @ bInterfaceClass
    .byte   0                          @ bInterfaceSubClass
    .byte   0                          @ bInterfaceProtocol
    .byte   0                          @ iInterface

    @ ---- Endpoint 1 OUT (bulk) --------------------------------------------
    .byte   USB_DESC_LEN_ENDPOINT      @ bLength
    .byte   USB_DESC_ENDPOINT          @ bDescriptorType
    .byte   0x01                       @ bEndpointAddress = EP1 OUT
    .byte   0x02                       @ bmAttributes = bulk
    .short  USB_EP_BULK_MAX_PACKET     @ wMaxPacketSize = 64
    .byte   0                          @ bInterval (bulk: ignored)

    @ ---- Endpoint 1 IN (bulk) ---------------------------------------------
    .byte   USB_DESC_LEN_ENDPOINT      @ bLength
    .byte   USB_DESC_ENDPOINT          @ bDescriptorType
    .byte   0x81                       @ bEndpointAddress = EP1 IN
    .byte   0x02                       @ bmAttributes = bulk
    .short  USB_EP_BULK_MAX_PACKET     @ wMaxPacketSize = 64
    .byte   0                          @ bInterval (bulk: ignored)
usb_config_descriptor_end:

@ ---- String 0: language ID (en-US) -----------------------------------------
    .global usb_string_lang
    .global usb_string_lang_end
usb_string_lang:
    .byte   4                          @ bLength
    .byte   USB_DESC_STRING            @ bDescriptorType
    .short  0x0409                     @ LANGID en-US
usb_string_lang_end:

@ ---- String 1: manufacturer ("ticktrace") -------------------------------------
    .global usb_string_manufacturer
    .global usb_string_manufacturer_end
usb_string_manufacturer:
    .byte   (usb_string_manufacturer_end - usb_string_manufacturer)
    .byte   USB_DESC_STRING
    .short  'r', 'p', '-', 'a', 's', 'm'
usb_string_manufacturer_end:

@ ---- String 2: product ("ticktrace CDC-ACM") ----------------------------------
    .global usb_string_product
    .global usb_string_product_end
usb_string_product:
    .byte   (usb_string_product_end - usb_string_product)
    .byte   USB_DESC_STRING
    .short  'r', 'p', '-', 'a', 's', 'm', ' ', 'C', 'D', 'C'
usb_string_product_end:

@ ---- String 3: serial ("000000000001") -------------------------------------
    .global usb_string_serial
    .global usb_string_serial_end
usb_string_serial:
    .byte   (usb_string_serial_end - usb_string_serial)
    .byte   USB_DESC_STRING
    .short  '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '1'
usb_string_serial_end:

@ ---- Descriptor lookup table ------------------------------------------------
@ Each entry: { ptr (4B), length (2B), type (1B), index (1B) } = 8 bytes.
@ The SETUP handler walks this table when it gets GET_DESCRIPTOR.
    .global usb_descriptor_table
    .global usb_descriptor_table_end
usb_descriptor_table:
    .word   usb_device_descriptor
    .short  USB_DESC_LEN_DEVICE
    .byte   USB_DESC_DEVICE
    .byte   0

    .word   usb_config_descriptor
    .short  USB_CONFIG_TOTAL_LEN
    .byte   USB_DESC_CONFIG
    .byte   0

    .word   usb_string_lang
    .short  4
    .byte   USB_DESC_STRING
    .byte   0

    .word   usb_string_manufacturer
    .short  (usb_string_manufacturer_end - usb_string_manufacturer)
    .byte   USB_DESC_STRING
    .byte   1

    .word   usb_string_product
    .short  (usb_string_product_end - usb_string_product)
    .byte   USB_DESC_STRING
    .byte   2

    .word   usb_string_serial
    .short  (usb_string_serial_end - usb_string_serial)
    .byte   USB_DESC_STRING
    .byte   3
usb_descriptor_table_end:
    .equ USB_DESC_TABLE_ENTRY_SIZE, 8
    .equ USB_DESC_TABLE_COUNT,      6
