# rp-asm

Pure-assembly SDK for the Raspberry Pi RP2350 (Cortex-M33).
**Motto: every cycle matters.**

No C compiler. The firmware is `arm-none-eabi-as` + `arm-none-eabi-ld`. The
only host tool is a 50-line Python UF2 packer.

v0.1 targets the Raspberry Pi Pico 2 (LED on GPIO25), runs entirely from
SRAM, and ships three subsystems:

| File          | Purpose                                                 |
| ------------- | ------------------------------------------------------- |
| `startup.S`   | Vector table, RP2350 `IMAGE_DEF` block, reset handler   |
| `gpio.S`      | LED init / single-store toggle via SIO XOR              |
| `uart.S`      | UART0 @ 115200 8N1 on GPIO0/1, blocking putc / puts     |
| `main.S`      | Banner + blink+tick loop                                |

Image size: **392 bytes of `.text`**, fits in two UF2 blocks.

## Build

```
sudo apt install binutils-arm-none-eabi python3
make
```

Output: `build/blinky.uf2`.

## Flash

1. Hold **BOOTSEL** on the Pico 2 while plugging in USB.
2. The `RP2350` mass-storage device appears.
3. Drag `build/blinky.uf2` onto it.

The bootrom loads the image into SRAM at `0x20000000`, validates the
`IMAGE_DEF` block at offset `0x40`, then jumps via the vector table.

Open a serial terminal at **115200 8N1** on the UART0 TX pin (GP0,
physical pin 1). You should see:

```
rp-asm v0.1 - every cycle matters
tick
tick
...
```

and the green LED blinks at ~2 Hz.

## Layout

```
include/rp2350.inc   Register map (atomic alias offsets, peripheral bases)
src/startup.S        Vectors + IMAGE_DEF + _reset
src/gpio.S           LED on GPIO25
src/uart.S           UART0 PL011 driver
src/main.S           Demo loop
link/sram.ld         512 KiB SRAM linker script, entry = _reset
tools/uf2.py         bin -> UF2 packer (family = rp2350-arm-s)
Makefile             AS / LD / OBJCOPY / UF2
```

## Design notes

- **Atomic register aliases.** Every peripheral write uses the
  `+0x2000` SET / `+0x3000` CLR / `+0x1000` XOR aliases instead of
  read-modify-write. One `STR`, two cycles, no scratch register, no
  race with interrupts.
- **`SIO_GPIO_OUT_XOR`** turns LED toggle into a single store.
  `gpio_led_toggle` is 3 instructions including the return.
- **No clock setup.** The bootrom hands off with `clk_sys = clk_peri =
  XOSC = 12 MHz`. UART baud divisors are computed for that. If you
  later wire up `pll_sys` at 150 MHz, update `uart.S` IBRD/FBRD.
- **Pad isolation.** RP2350 pads come out of reset with `ISO=1`
  (post-erratum behaviour from the A2 stepping). `gpio_led_init` and
  `uart0_init` both clear `ISO|OD` via the pad CLR alias.

## Roadmap

- [ ] `clocks.S` — PLL sys/usb to 150 MHz, switch `clk_peri`
- [ ] Recompute UART divisors after PLL bring-up
- [ ] Flash boot (XIP + custom boot2 stage)
- [ ] Core 1 launch (`sio_fifo` handshake)
- [ ] Cycle-counting (DWT) helpers
- [ ] PIO assembler examples
