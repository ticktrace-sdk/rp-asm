# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://amken.io>
#
# This file is part of the Amken RP2350 Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

"""T1 trace assertions for src/usb.S + the USB examples (M4-H).

This test exercises:

  - usb_device_init's RESETS clear, USB_MUXING / USB_PWR / MAIN_CTRL / INTE
    write sequence.
  - usb_ep_send copies bytes into the right DPRAM buffer and writes the
    EPx buf_ctrl with AVAILABLE | FULL | LAST | LENGTH | PID.
  - usb_ep_receive_arm sets AVAILABLE on the OUT buf_ctrl.
  - The SETUP handler dispatched on a GET_DESCRIPTOR(Device) request copies
    the 18-byte device descriptor into the EP0 IN buffer.
  - SET_ADDRESS latches into usb_pending_address and is applied later via
    BUFF_STATUS handling on EP0 IN.
  - SET_CONFIGURATION arms EP1 OUT (and writes ep_ctrl entries).
  - cdc_putc enqueues into the TX ring.
  - cdc_getc / cdc_available work on a pre-populated RX ring.

Plus an end-to-end check that build/usb_descriptor_only_demo.elf reaches
usb_device_init's MAIN_CTRL = CONTROLLER_EN store.
"""

import os
import struct
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

from harness import RP2350Sim, SRAM_BASE  # noqa: E402
from mocks_usb import (  # noqa: E402
    USBCTRL_DPRAM_BASE, USBCTRL_REGS_BASE,
    DPRAM_SETUP_PACKET, DPRAM_EP_CTRL_BASE, DPRAM_EP_BUF_CTRL,
    DPRAM_EP0_BUF0, DPRAM_EP1_OUT_BUF, DPRAM_EP1_IN_BUF,
    USB_ADDR_ENDP, USB_MAIN_CTRL, USB_SIE_CTRL, USB_SIE_STATUS,
    USB_BUFF_STATUS, USB_USB_MUXING, USB_USB_PWR, USB_INTE, USB_INTS,
    USB_MAIN_CTRL_CTRL_EN, USB_MUXING_TO_PHY, USB_MUXING_SOFTCON,
    USB_PWR_VBUS_DETECT, USB_PWR_VBUS_DETECT_OVR,
    USB_BUFCTRL_AVAILABLE_0, USB_BUFCTRL_FULL_0, USB_BUFCTRL_LAST_0,
    USB_BUFCTRL_PID_DATA1,
    USB_INT_BUFF_STATUS, USB_INT_BUS_RESET, USB_INT_SETUP_REQ,
    RESETS_USBCTRL, USBCTRL_IRQ,
    map_usb_region, mock_usb_resets_done, mock_usb_setup,
    mock_usb_buff_status, mock_usb_ints,
    read_dpram_buf, read_buf_ctrl, read_ep_ctrl,
)
from unicorn.arm_const import (  # noqa: E402
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_LR, UC_ARM_REG_PC,
)


# ----------------------------------------------------------------- fixtures


@pytest.fixture(scope="module")
def fixture_elf(tmp_path_factory):
    """Build tests/unicorn/fixtures/usb_api.S into an ELF with full symbols."""
    out = tmp_path_factory.mktemp("usb_fixture")
    src = os.path.join(HERE, "fixtures", "usb_api.S")
    obj = os.path.join(out, "usb_api.o")
    elf = os.path.join(out, "usb_api.elf")
    ld = os.path.join(out, "usb_api.ld")
    with open(ld, "w") as f:
        f.write(f"""ENTRY(_start)
MEMORY {{ SRAM(rwx) : ORIGIN = {hex(SRAM_BASE)}, LENGTH = 64K }}
SECTIONS {{
  .text {hex(SRAM_BASE)} : {{
    KEEP(*(.vectors))
    *(.text._start)
    *(.text*)
    *(.rodata*)
  }} > SRAM
  .bss : {{ *(.bss*) }} > SRAM
  _stack_top = ORIGIN(SRAM) + LENGTH(SRAM) - 4;
}}
""")
    asflags = ["-mcpu=cortex-m33", "-mthumb", "-mimplicit-it=always",
               "-I", os.path.join(REPO, "include")]
    # cwd = REPO so `.include "src/usb.S"` resolves.
    subprocess.check_call(
        ["arm-none-eabi-as", *asflags, "-o", obj, src],
        cwd=REPO,
    )
    subprocess.check_call(
        ["arm-none-eabi-ld", "-T", ld, "-nostdlib", "-o", elf, obj])
    return elf


def _load_fixture(elf):
    sim = RP2350Sim()
    sim.load_elf(elf)
    sim.mock_resets_done()
    map_usb_region(sim)
    return sim


def _call(sim, func_name, *args, max_steps=200_000):
    """Set r0..r{N-1} = args, point PC at func, LR at park sentinel."""
    park = sim.symbol("_park")
    func = sim.symbol(func_name)
    regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2]
    for i, v in enumerate(args):
        sim.uc.reg_write(regs[i], v & 0xFFFFFFFF)
    sim.uc.reg_write(UC_ARM_REG_LR, park | 1)
    sim.uc.reg_write(UC_ARM_REG_PC, func)
    sim.run_until_pc(park, max_steps=max_steps)


# -----------------------------------------------------------------------------
# usb_device_init
# -----------------------------------------------------------------------------


def test_usb_device_init_writes_resets_clr(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)
    _call(sim, "usb_device_init")

    RESETS_BASE = 0x40020000
    ATOMIC_CLR = 0x3000
    clr_writes = [w for w in sim.writes if w.addr == RESETS_BASE + ATOMIC_CLR]
    assert clr_writes, "usb_device_init never CLR'd RESETS_RESET"
    assert clr_writes[0].value == RESETS_USBCTRL, (
        f"reset clear value {clr_writes[0].value:#x}, want {RESETS_USBCTRL:#x}")


def test_usb_device_init_configures_phy_muxing(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)
    _call(sim, "usb_device_init")

    target = USBCTRL_REGS_BASE + USB_USB_MUXING
    ws = [w for w in sim.writes if w.addr == target]
    assert ws, "usb_device_init never wrote USB_MUXING"
    assert ws[0].value == (USB_MUXING_TO_PHY | USB_MUXING_SOFTCON), (
        f"USB_MUXING = {ws[0].value:#x}, want TO_PHY|SOFTCON")


def test_usb_device_init_forces_vbus_detect(fixture_elf):
    """Pico 2 has no VBUS sense; firmware must override VBUS_DETECT."""
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)
    _call(sim, "usb_device_init")

    target = USBCTRL_REGS_BASE + USB_USB_PWR
    ws = [w for w in sim.writes if w.addr == target]
    assert ws, "usb_device_init never wrote USB_PWR"
    expected = USB_PWR_VBUS_DETECT | USB_PWR_VBUS_DETECT_OVR
    assert ws[0].value == expected, (
        f"USB_PWR = {ws[0].value:#x}, want VBUS_DETECT|VBUS_DETECT_OVERRIDE_EN")


def test_usb_device_init_enables_controller(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)
    _call(sim, "usb_device_init")

    target = USBCTRL_REGS_BASE + USB_MAIN_CTRL
    ws = [w for w in sim.writes if w.addr == target]
    assert ws, "usb_device_init never wrote MAIN_CTRL"
    assert ws[0].value & USB_MAIN_CTRL_CTRL_EN, (
        f"MAIN_CTRL = {ws[0].value:#x}, CONTROLLER_EN bit not set")


def test_usb_device_init_enables_inte_bits(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)
    _call(sim, "usb_device_init")

    target = USBCTRL_REGS_BASE + USB_INTE
    ws = [w for w in sim.writes if w.addr == target]
    assert ws, "usb_device_init never wrote INTE"
    expected = USB_INT_SETUP_REQ | USB_INT_BUFF_STATUS | USB_INT_BUS_RESET
    assert ws[0].value == expected, (
        f"INTE = {ws[0].value:#x}, want SETUP_REQ|BUFF_STATUS|BUS_RESET")


# -----------------------------------------------------------------------------
# usb_ep_send / usb_ep_receive_arm
# -----------------------------------------------------------------------------


def test_ep_send_copies_bytes_to_dpram_ep0(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    # Plant 8 bytes at a known SRAM addr
    src = SRAM_BASE + 0x4000
    payload = bytes(range(8))
    sim.uc.mem_write(src, payload)

    # ep0, src, len=8
    _call(sim, "usb_ep_send", 0, src, 8)

    got = read_dpram_buf(sim, DPRAM_EP0_BUF0, 8)
    assert got == payload, f"DPRAM EP0 buf = {got!r}, want {payload!r}"


def test_ep_send_writes_buf_ctrl_with_correct_flags(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    src = SRAM_BASE + 0x4000
    sim.uc.mem_write(src, b"hello")
    _call(sim, "usb_ep_send", 0, src, 5)

    # buf_ctrl EP0 IN @ DPRAM + 0x80
    bc = read_buf_ctrl(sim, ep=0, dir_in=True)
    # Length in low 10 bits should be 5
    assert (bc & 0x3FF) == 5, f"LENGTH = {bc & 0x3FF}, want 5"
    assert bc & USB_BUFCTRL_AVAILABLE_0, "AVAILABLE bit not set"
    assert bc & USB_BUFCTRL_FULL_0,      "FULL bit not set"
    assert bc & USB_BUFCTRL_LAST_0,      "LAST bit not set"


def test_ep_send_zlp(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    _call(sim, "usb_send_zlp", 0)
    bc = read_buf_ctrl(sim, ep=0, dir_in=True)
    assert (bc & 0x3FF) == 0, f"LENGTH = {bc & 0x3FF}, want 0 (ZLP)"
    assert bc & USB_BUFCTRL_AVAILABLE_0, "ZLP must still set AVAILABLE"


def test_ep_send_targets_ep1_in_buffer(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    src = SRAM_BASE + 0x4000
    payload = b"echo me!"
    sim.uc.mem_write(src, payload)
    _call(sim, "usb_ep_send", 1, src, len(payload))

    got = read_dpram_buf(sim, DPRAM_EP1_IN_BUF, len(payload))
    assert got == payload, f"DPRAM EP1 IN buf = {got!r}, want {payload!r}"

    bc = read_buf_ctrl(sim, ep=1, dir_in=True)
    assert (bc & 0x3FF) == len(payload)
    assert bc & USB_BUFCTRL_AVAILABLE_0


def test_ep_receive_arm_sets_avail_on_out_buf_ctrl(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    _call(sim, "usb_ep_receive_arm", 1, 64)
    bc = read_buf_ctrl(sim, ep=1, dir_in=False)
    assert (bc & 0x3FF) == 64, f"LENGTH = {bc & 0x3FF}, want 64"
    assert bc & USB_BUFCTRL_AVAILABLE_0, "AVAILABLE not set on OUT buf_ctrl"


# -----------------------------------------------------------------------------
# SETUP handler
# -----------------------------------------------------------------------------


def test_get_descriptor_device_copies_18_bytes_to_ep0(fixture_elf):
    """SETUP = GET_DESCRIPTOR(Device) -> 18-byte device descriptor in EP0 IN."""
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    # bmRequestType=0x80 (IN, std, device); bRequest=GET_DESCRIPTOR (6)
    # wValue = (DESC_DEVICE=1) << 8 | 0; wIndex=0; wLength=18
    mock_usb_setup(sim,
                   bmRequestType=0x80, bRequest=6,
                   wValue=(1 << 8) | 0, wIndex=0, wLength=18)

    # Pretend the SETUP_REQ + BUFF_STATUS bits are pending in INTS so the
    # ISR walks the SETUP path.
    mock_usb_ints(sim, USB_INT_SETUP_REQ)

    _call(sim, "usb_device_isr", max_steps=500_000)

    # The first byte of the device descriptor is bLength = 18
    got = read_dpram_buf(sim, DPRAM_EP0_BUF0, 4)
    assert got[0] == 18, f"bLength = {got[0]}, want 18"
    assert got[1] == 1,  f"bDescriptorType = {got[1]}, want 1 (DEVICE)"
    # bcdUSB = 0x0200 (LE)
    assert got[2] == 0x00 and got[3] == 0x02, (
        f"bcdUSB bytes = {got[2]:#x} {got[3]:#x}, want 0x00 0x02")

    # And the buf_ctrl was kicked
    bc = read_buf_ctrl(sim, ep=0, dir_in=True)
    assert (bc & 0x3FF) == 18, f"LENGTH = {bc & 0x3FF}, want 18"
    assert bc & USB_BUFCTRL_AVAILABLE_0


def test_set_address_defers_to_pending_slot(fixture_elf):
    """SET_ADDRESS must NOT write ADDR_ENDP immediately; it must store the
    requested address into usb_pending_address and send a ZLP status stage."""
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    # bmRequestType=0x00 (OUT, std, device); bRequest=SET_ADDRESS (5)
    # wValue = 0x42 (new address); wLength=0
    mock_usb_setup(sim,
                   bmRequestType=0x00, bRequest=5,
                   wValue=0x42, wIndex=0, wLength=0)
    mock_usb_ints(sim, USB_INT_SETUP_REQ)

    _call(sim, "usb_device_isr", max_steps=200_000)

    # ADDR_ENDP must NOT have been written yet
    addr_writes = [w for w in sim.writes if w.addr == USBCTRL_REGS_BASE + USB_ADDR_ENDP]
    # If anything was written, it must be 0 (the bus_reset clear), not 0x42.
    for w in addr_writes:
        assert w.value != 0x42, (
            "SET_ADDRESS wrote 0x42 to ADDR_ENDP immediately; "
            "USB spec requires deferring until after the ZLP status stage")

    # And usb_pending_address byte should now be 0x42
    pending = sim.symbol("usb_pending_address")
    pa = sim.uc.mem_read(pending, 1)
    assert pa[0] == 0x42, f"usb_pending_address = {pa[0]:#x}, want 0x42"

    # ZLP should have been kicked on EP0 IN
    bc = read_buf_ctrl(sim, ep=0, dir_in=True)
    assert (bc & 0x3FF) == 0, f"LENGTH = {bc & 0x3FF}, want 0 (ZLP)"
    assert bc & USB_BUFCTRL_AVAILABLE_0


def test_set_configuration_arms_ep1_out_and_writes_ep_ctrl(fixture_elf):
    """SET_CONFIGURATION 1 must enable EP1 IN/OUT in ep_ctrl and arm EP1 OUT."""
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    # bmRequestType=0x00, bRequest=SET_CONFIGURATION (9), wValue=1
    mock_usb_setup(sim,
                   bmRequestType=0x00, bRequest=9,
                   wValue=1, wIndex=0, wLength=0)
    mock_usb_ints(sim, USB_INT_SETUP_REQ)

    _call(sim, "usb_device_isr", max_steps=300_000)

    # ep_ctrl[1].in: ENABLE bit (1 << 31), TYPE_BULK (2 << 26)
    epc = read_ep_ctrl(sim, ep=1, dir_in=True)
    assert epc & (1 << 31), f"ep_ctrl[1].in ENABLE = {epc:#x}, want bit 31 set"
    assert ((epc >> 26) & 0x3) == 2, (
        f"ep_ctrl[1].in TYPE = {(epc >> 26) & 3}, want 2 (BULK)")

    # ep_ctrl[1].out: same
    epc = read_ep_ctrl(sim, ep=1, dir_in=False)
    assert epc & (1 << 31), "ep_ctrl[1].out ENABLE not set"

    # EP1 OUT armed
    bc = read_buf_ctrl(sim, ep=1, dir_in=False)
    assert bc & USB_BUFCTRL_AVAILABLE_0, "EP1 OUT not armed after SET_CONFIGURATION"
    assert (bc & 0x3FF) == 64, f"EP1 OUT LENGTH = {bc & 0x3FF}, want 64"

    # And usb_configured byte set
    cfg = sim.symbol("usb_configured")
    c = sim.uc.mem_read(cfg, 1)
    assert c[0] == 1, f"usb_configured = {c[0]}, want 1"


def test_buff_status_ep0_in_applies_pending_address(fixture_elf):
    """When BUFF_STATUS shows EP0 IN done and usb_pending_address is non-zero,
    the ISR must finally write ADDR_ENDP with the pending address."""
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    # Pre-set usb_pending_address = 0x42 (simulate SET_ADDRESS earlier)
    pending = sim.symbol("usb_pending_address")
    sim.uc.mem_write(pending, b"\x42")

    # Pretend BUFF_STATUS bit 0 (EP0 IN) is set
    mock_usb_buff_status(sim, 1)
    mock_usb_ints(sim, USB_INT_BUFF_STATUS)

    _call(sim, "usb_device_isr", max_steps=200_000)

    # Now ADDR_ENDP should have 0x42
    addr_writes = [w for w in sim.writes if w.addr == USBCTRL_REGS_BASE + USB_ADDR_ENDP]
    assert any(w.value == 0x42 for w in addr_writes), (
        f"ADDR_ENDP never received 0x42; writes = "
        f"{[(hex(w.addr), hex(w.value)) for w in addr_writes]}")

    # usb_pending_address cleared
    pa = sim.uc.mem_read(pending, 1)
    assert pa[0] == 0, f"usb_pending_address = {pa[0]:#x}, want 0"


def test_buff_status_ep1_out_drains_into_rx_ring(fixture_elf):
    """BUFF_STATUS bit 3 (EP1 OUT) -> drain DPRAM -> RX ring; EP1 OUT re-armed."""
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    # Plant 4 bytes in the EP1 OUT DPRAM buffer
    payload = b"abcd"
    sim.uc.mem_write(USBCTRL_DPRAM_BASE + DPRAM_EP1_OUT_BUF, payload)
    # And set the LENGTH field of EP1 OUT buf_ctrl to 4
    bc_addr = USBCTRL_DPRAM_BASE + DPRAM_EP_BUF_CTRL + 8 * 1 + 4
    sim.poke32(bc_addr, len(payload))

    mock_usb_buff_status(sim, 1 << 3)
    mock_usb_ints(sim, USB_INT_BUFF_STATUS)

    _call(sim, "usb_device_isr", max_steps=300_000)

    # cdc_rx_buf should now contain 'abcd'
    rx_buf_addr = sim.symbol("cdc_rx_buf")
    got = bytes(sim.uc.mem_read(rx_buf_addr, 4))
    assert got == payload, f"cdc_rx_buf head = {got!r}, want {payload!r}"

    # EP1 OUT should have been re-armed (AVAILABLE set)
    bc = read_buf_ctrl(sim, ep=1, dir_in=False)
    assert bc & USB_BUFCTRL_AVAILABLE_0, "EP1 OUT not re-armed after drain"


# -----------------------------------------------------------------------------
# CDC ring buffers
# -----------------------------------------------------------------------------


def test_cdc_putc_pushes_byte_to_tx_ring(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    _call(sim, "cdc_putc", ord('Q'))
    tx_buf = sim.symbol("cdc_tx_buf")
    got = sim.uc.mem_read(tx_buf, 1)
    assert got[0] == ord('Q'), f"cdc_tx_buf[0] = {got[0]:#x}, want 'Q'"


def test_cdc_available_returns_ring_count(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    # Pre-populate rx ring: head=0, tail=5, buf[0..4] = 'A'..'E'
    head = sim.symbol("cdc_rx_head")
    tail = sim.symbol("cdc_rx_tail")
    rx_buf = sim.symbol("cdc_rx_buf")
    sim.uc.mem_write(head, struct.pack("<H", 0))
    sim.uc.mem_write(tail, struct.pack("<H", 5))
    sim.uc.mem_write(rx_buf, b"ABCDE")

    _call(sim, "cdc_available")
    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    assert r0 == 5, f"cdc_available = {r0}, want 5"


def test_cdc_getc_pops_one(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)

    head = sim.symbol("cdc_rx_head")
    tail = sim.symbol("cdc_rx_tail")
    rx_buf = sim.symbol("cdc_rx_buf")
    sim.uc.mem_write(head, struct.pack("<H", 0))
    sim.uc.mem_write(tail, struct.pack("<H", 1))
    sim.uc.mem_write(rx_buf, b"Z")

    _call(sim, "cdc_getc")
    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    assert r0 == ord('Z'), f"cdc_getc returned {r0:#x}, want 'Z'"

    # Head should have advanced
    h = struct.unpack("<H", sim.uc.mem_read(head, 2))[0]
    assert h == 1, f"head = {h}, want 1"


def test_cdc_getc_returns_minus_one_when_empty(fixture_elf):
    sim = _load_fixture(fixture_elf)
    mock_usb_resets_done(sim)
    _call(sim, "cdc_getc")
    r0 = sim.uc.reg_read(UC_ARM_REG_R0)
    assert r0 == 0xFFFFFFFF, f"empty cdc_getc returned {r0:#x}, want 0xFFFFFFFF"


# -----------------------------------------------------------------------------
# End-to-end: descriptor-only demo ELF reaches MAIN_CTRL = CONTROLLER_EN
# -----------------------------------------------------------------------------


USB_DESC_ONLY_ELF = os.path.join(REPO, "build", "usb_descriptor_only_demo.elf")


def _need_desc_only_elf():
    if not os.path.exists(USB_DESC_ONLY_ELF):
        subprocess.check_call(
            ["make", "-C", REPO, "build/usb_descriptor_only_demo.uf2"],
            stdout=subprocess.DEVNULL,
        )
    if not os.path.exists(USB_DESC_ONLY_ELF):
        pytest.skip(f"{USB_DESC_ONLY_ELF} missing and `make` did not produce it")


def test_descriptor_only_demo_reaches_main_ctrl_enable():
    """The descriptor-only demo runs through usb_device_init, which finally
    sets MAIN_CTRL = CONTROLLER_EN.  We watch for that store as the proof
    the controller bring-up sequence completed."""
    _need_desc_only_elf()
    sim = RP2350Sim()
    sim.load_elf(USB_DESC_ONLY_ELF)
    sim.mock_resets_done()
    sim.mock_xosc_stable()
    sim.mock_pll_locked(0x40050000)
    sim.mock_pll_locked(0x40058000)
    sim.mock_clk_selected()
    sim.mock_uart0_tx()
    map_usb_region(sim)
    mock_usb_resets_done(sim)

    # Run until MAIN_CTRL gets written - that's the last store in
    # usb_device_init.  Generous step cap because the clock bring-up takes
    # a while in the simulated tree.
    sim.run_until_write(USBCTRL_REGS_BASE + USB_MAIN_CTRL, max_steps=5_000_000)

    ws = [w for w in sim.writes if w.addr == USBCTRL_REGS_BASE + USB_MAIN_CTRL]
    assert ws and (ws[-1].value & USB_MAIN_CTRL_CTRL_EN), (
        f"MAIN_CTRL writes = {[hex(w.value) for w in ws]}, "
        "expected at least one with CONTROLLER_EN set")
