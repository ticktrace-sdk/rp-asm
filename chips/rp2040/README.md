# RP2040 — experimental

Cortex-M0+ peripheral drivers + boot path for the Raspberry Pi RP2040.

⚠ **See [`../../EXPERIMENTAL.md`](../../EXPERIMENTAL.md) for status, scope,
and the no-release policy that applies to everything under `chips/rp2040/`.**

## Layout

```
chips/rp2040/
├── include/rp2040.inc          register-map .equ constants
├── link/sram.ld                SRAM-only link script
├── link/flash.ld               flash-resident link script
├── src/
│   ├── boot2.S                 stage-2 bootloader (BOOT2 area, flash path only)
│   ├── startup.S               vector table + _reset
│   ├── xosc.S                  12 MHz crystal bring-up
│   ├── pll.S                   pll_sys @ 125 MHz, pll_usb @ 48 MHz
│   ├── clocks.S                clock-tree muxing + tick init
│   ├── watchdog.S              explicit-disable helper
│   ├── gpio.S                  GP25 LED out + UART pin funcsel
│   ├── uart.S                  UART0 init + putc/puts (PL011 quirks for M0+)
│   └── main.S                  M2 demo: bring-up + UART banner + blinky
└── tests/unicorn/
    ├── requirements.txt
    └── test_smoke.py           T1 image-shape + symbol-table assertions
```

## Build (out-of-tree, on this branch only)

The top-level `Makefile` on `main` doesn't yet know about `chips/rp2040/`.
For now build directly:

```bash
arm-none-eabi-as -mcpu=cortex-m0plus -mthumb \
    chips/rp2040/src/{startup,xosc,pll,clocks,watchdog,gpio,uart,main}.S \
    -o build/rp2040-m2.o
arm-none-eabi-ld -T chips/rp2040/link/sram.ld \
    build/rp2040-m2.o -o build/rp2040-m2.elf
python3 tools/uf2.py build/rp2040-m2.elf build/rp2040-m2.uf2
```

The UF2 family ID is `0xE48BFF56` (RP2040 SRAM family); `tools/uf2.py`
detects the load address and picks the right family automatically.

## Flash to hardware

Hold BOOTSEL, plug in a Pico (RP2040), drop `build/rp2040-m2.uf2` onto the
`RPI-RP2` mass-storage volume. Open a serial terminal on `/dev/ttyACM0` at
115200 8N1; expect:

```
ticktrace M2 RP2040 - clk_sys = 125 MHz
```

GP25 (the on-board LED) toggles at ~250 ms.
