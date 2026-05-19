# NVIC helpers

`src/nvic.S` is the minimal Cortex-M33 NVIC wrapper layer.  It exists
because the NVIC has six different register banks for what is
conceptually "set/clear/enable/pending/priority for IRQ N", and
forgetting which is which is a great way to spend an afternoon staring
at a chip that won't IRQ.

Datasheet reference: ARMv8-M Architecture Reference Manual sec B11.1
(NVIC).  RP2350 datasheet sec 3.2 lists the 52 external IRQ lines.

## API

| Function | Inputs | Effect |
| -------- | ------ | ------ |
| `nvic_enable_irq`      | `r0 = irq_num`                       | `ISER[irq>>5] \|= 1 << (irq & 31)` |
| `nvic_disable_irq`     | `r0 = irq_num`                       | `ICER[irq>>5] \|= 1 << (irq & 31)` |
| `nvic_set_pending`     | `r0 = irq_num`                       | `ISPR[irq>>5] \|= 1 << (irq & 31)` |
| `nvic_clear_pending`   | `r0 = irq_num`                       | `ICPR[irq>>5] \|= 1 << (irq & 31)` |
| `nvic_set_priority`    | `r0 = irq_num`, `r1 = priority(0..15)` | `IPR[irq] = priority << 4` |
| `nvic_install_handler` | `r0 = irq_num`, `r1 = handler`       | `vec[16 + irq] = handler \| 1` |

All clobber `r0-r3` only.  Caller-saved registers (`r4-r11`, `sp`,
`lr`) are preserved per the [calling conventions](calling.md).

## IRQ numbers

RP2350 has 52 external IRQs (0..51).  The canonical numbering is in
`include/usb.inc`, `include/uart.inc`, etc. -- each driver header
defines the IRQ constant it cares about (e.g. `USBCTRL_IRQ = 14`).
The list of names lives in the RP2350 datasheet sec 3.2; the most
commonly used:

```
 0  TIMER0_IRQ_0       14  USBCTRL_IRQ          26  SIO_IRQ_BELL
 4  TIMER1_IRQ_0       15  PIO0_IRQ_0           30  CLOCKS_IRQ
 8  PWM_IRQ_WRAP_0     21  IO_IRQ_BANK0         33  UART0_IRQ
10  DMA_IRQ_0          25  SIO_IRQ_FIFO         36  I2C0_IRQ
                                                39  TRNG_IRQ
```

## Standard wiring pattern

The "install + enable" idiom every IRQ-using driver follows:

```asm
movs    r0, #USBCTRL_IRQ            @ which IRQ line
ldr     r1, =usb_device_isr         @ which handler
bl      nvic_install_handler        @ patches vec[16+14] = isr | 1

movs    r0, #USBCTRL_IRQ
bl      nvic_enable_irq             @ NVIC_ISER bit on
```

After this, any USB event that ends up driving the USBCTRL line will
vector through `vec[30]` to `usb_device_isr`.  The handler is entered
in Handler mode with MSP, and must return with a normal `bx lr` once
all sources are W1C'd in the peripheral.

If you also want to set a non-default priority (e.g. to allow another
IRQ to preempt this one), do it between install and enable:

```asm
movs    r0, #USBCTRL_IRQ
movs    r1, #8                      @ 0 = highest, 15 = lowest
bl      nvic_set_priority
```

The scheduler (`src/sched.S`) is the only subsystem in the SDK that
relies on priorities for correctness; if you don't touch
`nvic_set_priority`, every IRQ is at priority 0 and they don't preempt
each other.

## Why `nvic_install_handler` needs a RAM vector table

The handler-install function patches:

```
*VTOR + 0x40 + irq_num*4 = handler | 1
```

`+0x40` skips the 16 ARMv8-M core vectors; `*VTOR` is read at runtime so
the function doesn't care where the table actually lives.

For **SRAM-resident** builds the table is at `0x20000000` (writable),
so the patch just works.  For **flash-resident** builds the table
would otherwise live at `0x10000000` (XIP flash, read-only) and the
store silently fails.  `_reset` in `src/startup.S` copies `_vectors`
into `_ram_vectors` (in `.bss`, 512-byte aligned) and points VTOR at
the copy *before* main runs, so handler installs work on both paths.
See [boot.md](boot.md) for the full vector-relocation story.

## Cycle costs

All five primitives are ~6-7 cycles in steady state (one `ldr` of the
base address from a literal pool, a couple of shifts to compute the
bit/index, one `str`).  This matters when you're toggling an IRQ
enable in a hot path; if you only enable / install once at boot, the
cost is irrelevant.

| Function | Cycles |
| -------- | ------ |
| `nvic_enable_irq`      | ~6 |
| `nvic_disable_irq`     | ~6 |
| `nvic_set_pending`     | ~6 |
| `nvic_clear_pending`   | ~6 |
| `nvic_set_priority`    | ~7 |
| `nvic_install_handler` | ~6 (one extra load for VTOR) |

## See also

- [boot.md](boot.md): vector-table layout, RAM relocation, why
  `nvic_install_handler` needs a writable table.
- [calling.md](calling.md): ABI for handlers, scratch-register rules,
  W1C-the-peripheral convention.
- [sched.md](sched.md): uses `nvic_set_priority` extensively for the
  QV-style scheduler.
- `examples/timer_alarm_demo.S`, `examples/usb_cdc_echo_demo.S`,
  `examples/sched_demo.S`: worked examples of the install + enable
  pattern.
