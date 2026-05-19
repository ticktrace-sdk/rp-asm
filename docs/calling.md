# ticktrace calling conventions

All drivers in `src/` follow AAPCS (ARM Architecture Procedure Call Standard),
because they need to be callable from each other and from user code without
surprises. This page documents what that means in practice and gives a
worked example for every common case.

## The contract every function obeys

| Register | Role                                | Preserved by callee? |
| -------- | ----------------------------------- | -------------------- |
| `r0`     | first arg / return value            | **no**               |
| `r1`     | second arg / second return word     | **no**               |
| `r2`     | third arg                           | **no**               |
| `r3`     | fourth arg                          | **no**               |
| `r4`–`r11` | scratch                           | **yes**, must save/restore |
| `r12` (IP) | intra-procedure scratch           | **no**               |
| `r13` (SP) | stack pointer                     | **yes**, kept 8-byte aligned at call boundaries |
| `r14` (LR) | return address                    | **no** at the function level (it gets clobbered by `bl`) |
| `r15` (PC) | program counter                   | n/a                  |

Every public driver function in this SDK:

1. Takes up to 4 word-sized args in `r0`–`r3`.
2. Returns at most 64 bits, in `r0` (low) and optionally `r1` (high).
3. May freely clobber `r0`–`r3`, `r12`, and the flags.
4. Saves and restores `r4`–`r11` if it uses them.
5. Keeps `sp` 8-byte aligned across calls.
6. Returns with `bx lr` (or `pop {…, pc}` if it pushed `lr`).

If you're calling from one piece of asm to another and either side breaks
this, you'll see one of three failure modes: a corrupted return value, a
crash on the next `pop`, or (worst) silent data corruption later.

## Calling a driver from your asm

The minimal recipe is "set up `r0`–`r3` and `bl`":

```asm
    @ Toggle the LED on GP25
    movs    r0, #25         @ pin
    bl      gpio_toggle
```

For functions that return:

```asm
    @ Read GP3, branch if low
    movs    r0, #3
    bl      gpio_get        @ r0 = 0 or 1
    cbz     r0, .Linput_low
```

For functions taking more than 4 args, push the rest on the stack
**right-to-left**, 8-byte aligned. None of the v0.1 drivers do this, so
you can usually ignore it.

## Calling another driver from your driver

Same convention. If your function takes args of its own that you need to
keep through a `bl`, save them in `r4`–`r7` (callee-saved) before the call.
Worked example from `uart0_init` (paraphrased):

```asm
uart0_init:
    push    {r4, lr}

    @ Bring UART0 out of reset
    movs    r0, #0          @ idx
    bl      uart_resets_deassert

    @ Configure pads + funcsel on GP0/GP1.  Two pin args we need to remember.
    movs    r4, #0          @ stash GP0 in r4
    movs    r0, r4
    movs    r1, #2          @ GPIO_FUNC_UART
    bl      gpio_set_function

    movs    r0, #1          @ GP1
    movs    r1, #2
    bl      gpio_set_function

    @ ... baud setup, etc.

    pop     {r4, pc}
```

Things to notice:

- We `push {r4, lr}` on entry so we can use `r4` and so the eventual
  `pop {r4, pc}` does both restore + return in one instruction.
- We don't touch `r5`–`r11`, so we don't have to save them.
- `gpio_set_function` clobbers `r0`–`r3`; that's why we kept GP0 in `r4`.
- `pop {r4, pc}` is the standard return-with-restore idiom. The `pc` slot
  takes the value we previously pushed from `lr`. The CPU automatically
  treats the low bit as the Thumb-state indicator.

## Stack discipline

Every `push` and `pop` should be paired. The two safe patterns are:

```asm
@ Pattern A: leaf-ish function with a single early-exit
    push    {r4, r5, lr}
    @ ... body, may use r4 r5 ...
    pop     {r4, r5, pc}
```

```asm
@ Pattern B: function with multiple exits
    push    {r4, lr}
    cmp     r0, #0
    bne     .Ldo_work
    pop     {r4, pc}        @ early return
.Ldo_work:
    @ ...
    pop     {r4, pc}
```

**Never** mix `push {r4, lr}` with `pop {r4, lr}` (you'd have to follow with
`bx lr`, wasted cycle). And never branch out of a function that pushed
something without popping first.

The stack must stay 8-byte aligned at every external call boundary. If you
`push {r4, lr}` (two words = 8 B), good. If you `push {r4, r5, lr}` (three
words = 12 B, misaligned), bridge with `push {r4, r5, r6, lr}` (four words
= 16 B) or `sub sp, #4` to fix it.

## SP-relative scratch space

If you need a small RAM buffer, allocate it on the stack:

```asm
my_func:
    push    {r4, lr}
    sub     sp, #16             @ 16 bytes scratch, sp stays aligned

    mov     r4, sp              @ pointer to the buffer
    @ ... use [r4, #0..#15] ...

    add     sp, #16             @ release
    pop     {r4, pc}
```

Keep the allocation a multiple of 8 bytes. `sha256_compute` uses this
pattern to build a 128-byte padded final block without static state.

## Branching to a function (tail call)

If your function ends with calling another and returning its result, use
`b` instead of `bl`:

```asm
gpio_led_init:
    movs    r0, #25
    b       gpio_init       @ tail-call; uses our caller's LR
```

Saves one cycle (the `pop {pc}`) and one stack frame. Only valid if you
haven't pushed anything (otherwise your stack would leak).

## Direct register conventions in this SDK

These are project-local choices stacked on top of AAPCS:

- **Per-peripheral instance index** (UART0/1, I2C0/1, SPI0/1, PIO0/1/2) is
  always the **first** arg in `r0`. So `uart_init(idx, baud, clk_peri)`,
  `i2c_init(idx, hz)`, `pio_sm_set_clkdiv(pio_idx, sm, int, frac)`, etc.

- **Pin numbers** in GPIO calls cover both banks (0–47); the driver picks
  the right SIO `_HI` register internally.

- **Atomic alias writes** (the `+0x1000`/`+0x2000`/`+0x3000` windows on
  every APB peripheral) are how every driver does read-modify-write. If
  you compose drivers, your code can do the same: a single `str` to the
  CLR alias clears specific bits without disturbing the rest of the
  register, atomic with respect to any other master on the bus.

- **Functions that block** (`uart_putc_blocking`, `sha256_get_digest`,
  `pio_sm_put`, …) spin on a status bit; they do not enable IRQs or wfi.
  If you want async behaviour, use the IRQ-mode entry points
  (`uart_set_irqs_enabled`, `pio_sm_set_irq_handler`, …) and the NVIC
  helpers in `src/nvic.S`.

- **Driver init order**. The conventional `main` calls (this is exactly
  what `src/main.S` does):

  ```
  xosc_init
  pll_sys_150_mhz
  pll_usb_48_mhz
  clocks_init
  tick_init
  watchdog_disable
  gpio_led_init
  uart0_init
  clocks_post_pll_uart_baud_fixup       <-- only after PLL bring-up
  ```

  Every driver beyond that point (DMA, PWM, ADC, …) just needs its own
  `*_init` called once before use, in any order.

## Calling user code from interrupt handlers

Vectors live in SRAM at `_vectors` (the linker script + startup.S put them
there). Each entry is a 32-bit word holding the handler address with the
Thumb bit (`+1`) set.

To install your own handler from running code:

```asm
    ldr     r0, =my_handler
    orrs    r0, #1                  @ Thumb bit
    @ The Cortex-M33 IRQ vectors start at _vectors + 16*4 (16 exception
    @ slots before the first external IRQ).
    ldr     r1, =_vectors + 16*4 + 14*4   @ e.g. USBCTRL_IRQ = 14
    str     r0, [r1]
```

Or use the helper from `src/nvic.S`:

```asm
    ldr     r0, =my_handler
    movs    r1, #14                 @ IRQ number
    bl      nvic_install_handler    @ patches the vector and enables NVIC
```

Inside the handler, follow AAPCS like any function. The Cortex-M ABI is
generous: hardware already saves `r0`–`r3`, `r12`, `lr`, return addr, and
xPSR on entry to an exception, so a handler that only uses `r0`–`r3` and
`r12` doesn't need to push anything. If you touch `r4`–`r11`, save them
yourself. Return with `bx lr` and the magic `EXC_RETURN` value in `lr`
takes care of restoring CPU state.

## Cycle costs you should expect

Numbers measured on `arm-none-eabi-as` output for Cortex-M33 running from
SRAM with no wait states. They include the final `bx lr`.

| Call                              | Cycles | Stores |
| --------------------------------- | -----: | -----: |
| `gpio_put` / `gpio_toggle`        | 4      | 1      |
| `gpio_set_function`               | 8      | 1      |
| `gpio_init`                       | ~25    | 4      |
| `pwm_set_chan_level` (STRH path)  | 9      | 1      |
| `uart_is_writable`                | 4      | 0      |
| `uart_putc_blocking` (FIFO ready) | ~10    | 1      |
| `uart_set_baudrate`               | ~30    | 3      |
| `sha256_write_word` (FIFO ready)  | ~6     | 1      |
| `dma_channel_configure` (no trig) | ~11    | 4      |
| `pio_sm_put` (FIFO ready)         | ~10    | 1      |

A function that crosses two `bl`s and three peripheral stores still
finishes in fewer than 30 cycles. Every cycle matters.
