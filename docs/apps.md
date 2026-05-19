# Building apps with ticktrace

This is the practical companion to `docs/calling.md`. That one explains the
contract; this one walks you through using it. By the end you'll know how
to write your own Pico 2 app, compose it with the SDK drivers, build a
UF2, and (when something goes wrong) debug it.

For the formal calling-convention rules, read `docs/calling.md` first.
This page assumes you've skimmed it.

## TL;DR: a minimum app in 30 lines

Drop this file at `examples/myapp.S`:

```asm
@ examples/myapp.S - bare-minimum ticktrace app
    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .rodata.banner, "a"
banner: .asciz "hello from myapp\r\n"

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ Bring up the standard clock tree (150 MHz / 48 MHz) + UART + LED.
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      gpio_led_init
    bl      uart0_init
    bl      clocks_post_pll_uart_baud_fixup

    @ Say hello.
    ldr     r0, =banner
    bl      uart0_puts

    @ Blink forever.
.Lloop:
    bl      gpio_led_toggle
    ldr     r0, =12500000        @ ~250 ms at 150 MHz
1:  subs    r0, #1
    bne     1b
    b       .Lloop
```

Build for real hardware:

```
make build/myapp_flash.uf2
# BOOTSEL + drag build/myapp_flash.uf2 onto the RP2350 USB drive
```

The `_flash` suffix links the image at `0x10000000` (the XIP window), which
is what actually runs reliably on Pico 2 (RP2350-A2) silicon.  The plain
`make build/myapp.uf2` produces an SRAM-resident image at `0x20000000`;
that's what the T1/T2/T3 test harness uses, but the bootrom does not
hand off reliably to SRAM-only images on shipping Pico 2 boards.  See
`docs/boot.md` for the bring-up details that justify this split.

That's the whole development cycle. The rest of this doc is about
extending it: defining your own functions, organising code across files,
hooking interrupts, and so on.

## How a function is created, used, and destroyed

In asm there are no objects with constructors or destructors. What we
mean by "create" and "destroy" is the stack frame: every function call
creates a new one (the prologue) and tears it down before returning
(the epilogue).

### The simplest case: leaf function

A *leaf* function calls nothing else. No `bl`, no need to save `lr`,
nothing to push.

```asm
@ Add two numbers.   r0 = a, r1 = b. Returns r0 = a+b.
    .section .text.add2, "ax"
    .thumb_func
    .global  add2
add2:
    adds    r0, r0, r1
    bx      lr                          @ return; lr was set by our caller's `bl`
```

No prologue, no epilogue; just operate on the inputs and `bx lr`.

Use it:

```asm
    movs    r0, #3
    movs    r1, #4
    bl      add2                        @ r0 now holds 7
```

### Adding work that needs saved registers

If you need more scratch than `r0`–`r3` give you, or if you call another
function, you need a stack frame:

```asm
@ sum_of_3_inputs(r0=a, r1=b, r2=c) - returns r0 = a + b + c
    .section .text.sum3, "ax"
    .thumb_func
    .global  sum3
sum3:
    push    {r4, lr}                    @ "create" the frame: save r4 + return addr
    mov     r4, r2                      @ stash c (r2 will be clobbered by add2)

    bl      add2                        @ r0 = a + b

    mov     r1, r4                      @ r1 = c (we kept it in callee-saved r4)
    bl      add2                        @ r0 = (a+b) + c

    pop     {r4, pc}                    @ "destroy" the frame and return
```

Three things to notice:

- **`push {r4, lr}` is the prologue.** It saves callee-saved registers
  we'll touch, plus `lr` so we have a return address to come back to.
  Two words = 8 bytes = stack stays 8-byte aligned.
- **`pop {r4, pc}` is the epilogue.** It restores `r4` and pops `lr`
  straight into `pc`; one instruction does both restore and return.
  The CPU treats the low bit of `pc` as the Thumb-state indicator, so
  the value we pushed (with the original Thumb bit set) works exactly
  right.
- **Symmetry.** Every register listed in `push` must also be in `pop`,
  with the substitution `lr → pc`. If they don't match, the stack
  pointer ends up wrong and the next caller crashes.

### Local scratch buffer ("stack alloc")

If you need a temporary RAM buffer, allocate it on the stack:

```asm
    .section .text.with_scratch, "ax"
    .thumb_func
    .global  with_scratch
with_scratch:
    push    {r4, lr}
    sub     sp, #16                     @ 16 bytes of scratch; sp stays aligned

    mov     r4, sp                      @ r4 = pointer to our buffer
    @ ... fill / use [r4, #0..#15] ...

    add     sp, #16                     @ release the scratch
    pop     {r4, pc}
```

`sha256_compute` does exactly this for its 128-byte padding buffer:

```asm
sha256_compute:
    push    {r4, r5, r6, r7, r8, lr}
    sub     sp, #128                    @ two scratch SHA-256 blocks
    ...
    add     sp, #128
    pop     {r4, r5, r6, r7, r8, pc}
```

Keep the allocation a multiple of 8 bytes so `sp` stays 8-byte aligned.

### Tail-call: skip the epilogue when you're already done

If the *last* thing your function does is call another function and
return its result, use `b` (branch) instead of `bl` (branch-and-link):

```asm
@ Toggle the LED on GP25.  One-liner.
    .section .text.gpio_led_toggle, "ax"
    .thumb_func
    .global  gpio_led_toggle
gpio_led_toggle:
    movs    r0, #25                     @ pin
    b       gpio_toggle                 @ tail-call; lr stays our caller's
```

The callee uses our caller's `lr`, so it returns directly to our
caller; we never get control back, never need an epilogue. Saves one
cycle and one stack slot.

**Only valid if your function hasn't pushed anything yet.** If you did
`push {r4, lr}` first, a `b` (instead of `pop`-then-return) would leak
the stack frame.

## Calling drivers from your app

Every driver follows the same pattern:

1. Call its `*_init` once at startup.
2. Set whatever per-instance config it needs.
3. Call the public data-path entry points whenever you want to do work.

The conventional init order is whatever appears in `src/main.S`:

```asm
    bl      xosc_init                       @ XOSC stable
    bl      pll_sys_150_mhz                 @ pll_sys = 150 MHz
    bl      pll_usb_48_mhz                  @ pll_usb = 48 MHz
    bl      clocks_init                     @ wire muxes -> clk_sys = 150 MHz
    bl      tick_init                       @ 1 MHz tick to TIMER0/1/WDG
    bl      watchdog_disable                @ explicit safe state
    bl      gpio_led_init                   @ LED on GP25
    bl      uart0_init                      @ UART0 @ 115200, computed for 12 MHz
    bl      clocks_post_pll_uart_baud_fixup @ retune IBRD/FBRD for 150 MHz
```

Anything else (`dma_init`, `pwm_init`, `i2c_init`, `spi_init`,
`adc_init`, `sha256_init`, `pio_init`, `trng_init`, ...) just needs its
own init call once, in any order.

After that, just call into the public API:

```asm
    @ Sample the temperature sensor.
    movs    r0, #8                  @ ADC channel 8 = temp sensor
    bl      adc_select_input
    bl      adc_read                @ r0 = 12-bit raw count
```

The full per-peripheral API surface is documented in
`docs/<peripheral>.md`.

## Multi-file apps

For anything bigger than 100 lines, split it. Drop additional source
files in `src/` and append them to `DRIVER_SRC` in the Makefile:

```make
# Makefile - append at the bottom of the DRIVER_SRC section
DRIVER_SRC += src/myapp_lib.S
```

Then your app file can call into it just like a driver:

```asm
@ src/myapp_lib.S - your custom utility module
    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .text.celsius_from_raw, "ax"
    .thumb_func
    .global  celsius_from_raw
celsius_from_raw:
    @ Convert a raw ADC count (r0) to centi-degrees C (r0).
    @ ... do the math ...
    bx      lr
```

```asm
@ examples/temp_logger.S - uses your utility
    movs    r0, #8
    bl      adc_select_input
    bl      adc_read
    bl      celsius_from_raw            @ r0 now centi-°C
    @ ... print ...
```

### Why each function gets its own `.section`

You'll notice every driver function lives in its own
`.section .text.<name>, "ax"`. That's deliberate: it lets
`--gc-sections` (we pass it to `ld` by default) drop unreferenced
functions from your final binary. If you call `gpio_put` but never
`gpio_get`, the linker throws `gpio_get` away. Image size scales with
what you actually use, not what's available.

If you put everything in one big `.section .text`, you'd pay for the
whole driver regardless of which entry points you call. So: one
`.section .text.<name>, "ax"` per function. Always.

### Putting public symbols in headers

If multiple files want to share a constant (register address, bit mask,
pin number) put it in `include/<name>.inc` and `.include` it. Look at
`include/rp2350.inc` for the style. Every public symbol there is a
`.equ` definition; the assembler resolves them at assembly time so they
cost zero bytes in the image.

## Wiring up an IRQ handler

Cortex-M has a vector table; on RP2350 we put it at the very start of
SRAM (look at `src/startup.S`). Each entry holds a 32-bit handler
address with the Thumb bit (`+1`) set.

The first 16 entries are CPU-defined exceptions (SP_init, Reset, NMI,
HardFault, ...). External IRQs start at vector index 16. So the vector
slot for NVIC IRQ N lives at `_vectors + (16+N)*4`.

To install your own handler at runtime, use the NVIC helpers from
`src/nvic.S`:

```asm
    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ... clock + peripheral bring-up ...

    @ Install our handler for TIMER0 alarm 0 (IRQ line 0).
    ldr     r0, =my_alarm_handler
    movs    r1, #0                      @ IRQ number
    bl      nvic_install_handler        @ patches vec + enables NVIC line

    @ Arm the alarm to fire 100 ms from now.
    movs    r0, #0                      @ timer 0
    movs    r1, #0                      @ alarm 0
    bl      time_us_32                  @ r0 = current micros
    add     r2, r0, #100000
    movs    r3, #0
    bl      alarm_set

.Lloop:
    wfi                                 @ sleep until next IRQ
    b       .Lloop

@ ------------------------------------------------------------------ ISR
@ The ISR follows AAPCS like any other function.  Hardware already
@ saves r0-r3, r12, lr, return PC and xPSR on entry, so we only have
@ to save r4-r11 if we touch them.
@ ------------------------------------------------------------------
    .section .text.my_alarm_handler, "ax"
    .thumb_func
    .global  my_alarm_handler
my_alarm_handler:
    @ Acknowledge the alarm so the IRQ doesn't re-fire instantly.
    movs    r0, #0                      @ timer 0
    movs    r1, #0                      @ alarm 0
    bl      alarm_clear_irq

    @ Toggle the LED.
    movs    r0, #25
    bl      gpio_toggle

    @ Re-arm for another 100 ms.
    movs    r0, #0
    movs    r1, #0
    bl      time_us_32
    add     r2, r0, #100000
    movs    r3, #0
    bl      alarm_set

    bx      lr                          @ EXC_RETURN value in lr restores CPU state
```

Pay attention to the AAPCS rules even inside an ISR: if you touch
`r4`–`r11`, push them on entry. The hardware doesn't save those.

## Build system in one paragraph

`make` reads `Makefile` and notices:

- `DRIVER_SRC` is a list of `src/*.S` files. Each becomes a `.o` and
  links into every image.
- `examples/*.S` is auto-discovered by a wildcard. Each one builds to
  `build/<name>.elf` → `.bin` → `.uf2`. So drop a new file in
  `examples/` and `make build/<name>.uf2` Just Works.
- The default `main.S` (which builds to `build/blinky.uf2`) is the
  M2-default clock-bring-up + banner + blink. Replace its content if
  you want a different default firmware, or just ignore it and build
  your own example.

There's no separate compile step. `arm-none-eabi-as` assembles, `ld`
links, `objcopy` flattens to raw binary, and `tools/bin/rpasm uf2 pack`
wraps it into the UF2 format the RP2350 bootrom expects.

## Debugging

### "My UART is silent / wrong baud"

Did you call `clocks_post_pll_uart_baud_fixup` after `clocks_init`?
That's the single most common bug. Before the fixup, UART is configured
for clk_peri=12 MHz; after `clocks_init` ramps to 150 MHz it would run
at 1/12.5 the intended rate.

### "My pin won't drive"

RP2350 pads boot with `ISO=1` and `OD=1` (datasheet §9.3.1). Your
driver code MUST clear those before SIO output reaches the pin. Every
SDK driver does this in its `*_init`; if you're writing your own and
the pin won't move, that's where to look first.

### "It hangs at startup"

Almost always a spin-loop on a status bit. The common culprits:

- `xosc_init` waiting for STABLE: usually means the crystal isn't
  oscillating (wrong board?).
- A PLL wait-for-LOCK never exits: bad FBDIV / REFDIV combination.
- `*_resets_deassert` waiting for RESET_DONE: peripheral never
  came out of reset.

Get an objdump and read your `_reset` path:

```sh
arm-none-eabi-objdump -d build/myapp.elf | less
```

### "I want a trace of what happened"

The T1 Unicorn harness can run your firmware and print every MMIO
write. Quick recipe: copy `tests/unicorn/test_v01_blinky.py`, point it
at `build/myapp.elf`, and replace the assertion with
`print(sim.writes)`. Run with `pytest -s`.

### "I want to know how many cycles a function takes"

Cycle-counting helpers via DWT are on the roadmap (M8). Until then,
`arm-none-eabi-objdump -d` and count: Thumb-2 single-cycle for most
ops, 2 cycles for loads, 1–3 for branches, 1 for `udiv` on M33.
`docs/calling.md` has measured numbers for every public driver function.

## Where to go next

- `docs/calling.md`: the AAPCS contract in full
- `docs/<peripheral>.md`: every public API
- `src/main.S`: minimal working firmware to use as a template
- `examples/`: every peripheral has a working demo to crib from
- `tests/unicorn/test_*.py`: the harness can drive your own ELF too
