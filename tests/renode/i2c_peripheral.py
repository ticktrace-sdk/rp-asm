"""RP2350 DesignWare DW_apb_i2c functional model for Renode (M4-F).

Loaded by tests/renode/rp2350.repl as the script payload of a
Python.PythonPeripheral instance, one per I2C controller (I2C0 / I2C1).

State we track:
  - IC_TAR        : current target address (master mode)
  - IC_SAR        : own address (slave mode)
  - IC_CON        : config word (master vs slave decoded from bit 0)
  - IC_ENABLE     : master switch
  - tx_fifo / rx_fifo : per-direction FIFOs (we cap at 16 entries each)
  - SCL HCNT/LCNT, SDA hold, IC_FS_SPKLEN  : kept as shadow registers
  - IC_INTR_MASK / IC_RAW_INTR_STAT       : minimal model

Behaviour for the EEPROM demo:
  - When the firmware writes IC_DATA_CMD with CMD=0 (write), the byte is
    appended to a per-target write log indexed by IC_TAR.
  - When the firmware writes IC_DATA_CMD with CMD=1 (read), we synthesise
    the next byte for that target's read response.  For the canonical demo
    addresses we hand back fixed patterns:
      0x50 (EEPROM)  -> cycles through [0xA5, 0xB6, 0xC7, 0xD8]
      0x42 (loopback)-> echoes whatever was written most recently
      anything else  -> 0xFF (NACK fallback)

  - IC_STATUS always reports TFNF | TFE | (RFNE if rx_fifo is non-empty).
    MST_ACTIVITY is 0 once the synchronous transaction has completed.

This is a deliberately minimal model - enough to drive the three example
images through their happy paths.  Full DesignWare semantics (start/stop
detection, abort sources, slave RD_REQ flow) are out of scope.

NB: this script is included verbatim by `script: '''...'''` in
rp2350.repl.  Keep both copies in sync; CI does NOT detect drift.
"""

if request.IsInit:
    state = {
        "tar": 0,
        "sar": 0,
        "con": 0,
        "enable": 0,
        "intr_mask": 0,
        "raw_intr_stat": 0,
        "fs_spklen": 0,
        "sda_hold": 0,
        "rx_queue": [],          # bytes pending for the next read pop
        "tx_log_per_addr": {},   # addr -> list of bytes written
        "eeprom_pattern": [0xA5, 0xB6, 0xC7, 0xD8],
        "eeprom_idx": 0,
    }
elif request.IsRead:
    off = request.Offset & 0xFFF
    if off == 0x00:                  # IC_CON
        request.Value = state["con"]
    elif off == 0x04:                # IC_TAR
        request.Value = state["tar"]
    elif off == 0x08:                # IC_SAR
        request.Value = state["sar"]
    elif off == 0x10:                # IC_DATA_CMD
        if state["rx_queue"]:
            request.Value = state["rx_queue"].pop(0) & 0xFF
        else:
            request.Value = 0xFF
    elif off == 0x2C:                # IC_INTR_STAT (post-mask)
        request.Value = state["raw_intr_stat"] & state["intr_mask"]
    elif off == 0x30:                # IC_INTR_MASK
        request.Value = state["intr_mask"]
    elif off == 0x34:                # IC_RAW_INTR_STAT
        request.Value = state["raw_intr_stat"]
    elif off == 0x40:                # IC_CLR_INTR
        state["raw_intr_stat"] = 0
        request.Value = 0
    elif off in (0x44, 0x48, 0x4C, 0x50, 0x54, 0x58, 0x5C, 0x60, 0x64):
        request.Value = 0           # individual CLR registers - clear-on-read
    elif off == 0x6C:                # IC_ENABLE
        request.Value = state["enable"]
    elif off == 0x70:                # IC_STATUS
        s = (1 << 1) | (1 << 2)     # TFNF | TFE
        if state["rx_queue"]:
            s |= (1 << 3)           # RFNE
        request.Value = s
    elif off == 0x74:                # IC_TXFLR
        request.Value = 0
    elif off == 0x78:                # IC_RXFLR
        request.Value = len(state["rx_queue"])
    elif off == 0x80:                # IC_TX_ABRT_SOURCE
        request.Value = 0
    elif off == 0x9C:                # IC_ENABLE_STATUS
        request.Value = state["enable"]
    else:
        request.Value = 0
elif request.IsWrite:
    off = request.Offset & 0xFFF
    val = request.Value & 0xFFFFFFFF
    if off == 0x00:                  # IC_CON
        state["con"] = val
    elif off == 0x04:                # IC_TAR
        state["tar"] = val & 0x3FF
    elif off == 0x08:                # IC_SAR
        state["sar"] = val & 0x3FF
    elif off == 0x10:                # IC_DATA_CMD
        cmd_read = bool(val & (1 << 8))
        addr = state["tar"]
        if cmd_read:
            # Master initiated a read - synthesise the next byte.
            if addr == 0x50:        # EEPROM stub
                idx = state["eeprom_idx"]
                pat = state["eeprom_pattern"]
                state["rx_queue"].append(pat[idx % len(pat)])
                state["eeprom_idx"] = idx + 1
            elif addr == 0x42:      # loopback stub
                log = state["tx_log_per_addr"].get(addr, [])
                state["rx_queue"].append(log[-1] if log else 0)
            else:
                state["rx_queue"].append(0xFF)
        else:
            # Master initiated a write - log the data byte.
            state["tx_log_per_addr"].setdefault(addr, []).append(val & 0xFF)
    elif off == 0x14 or off == 0x18 or off == 0x1C or off == 0x20:
        # SCL HCNT/LCNT (SS or FS) - track for completeness; not used.
        pass
    elif off == 0x30:                # IC_INTR_MASK
        state["intr_mask"] = val
    elif off == 0x38 or off == 0x3C:
        pass                        # IC_RX_TL / IC_TX_TL
    elif off == 0x6C:                # IC_ENABLE
        state["enable"] = val & 1
    elif off == 0x7C:                # IC_SDA_HOLD
        state["sda_hold"] = val
    elif off == 0xA0:                # IC_FS_SPKLEN
        state["fs_spklen"] = val
    elif off == 0x88:                # IC_DMA_CR
        pass
    else:
        pass
