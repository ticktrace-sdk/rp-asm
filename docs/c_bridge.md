# C bridge

Opt-in C ABI on top of the ticktrace core. Write your application in C; the
drivers stay in asm. AAPCS makes the call boundary free.

> **Branch note:** lives on `claude/c-rust-bridge`. The asm-only mainline
> never references C code; the bridge is strictly additive.

## What ships

| File | Purpose |
| ---- | ------- |
| `c_bridge/runtime.S`        | `_c_runtime_init()`: zeroes `.bss` so C globals read as 0 |
| `c_bridge/asm_libc.S`       | `memset` / `memcpy` / `memcmp` (gcc emits implicit calls to these) |
| `c_bridge/include/rp_asm.h` | C prototypes for every public asm driver function |
| `c_apps/hello_c/`           | Example: blink + UART hex dump using DWT timing |
| Makefile `c-apps` target    | Compiles and links any `c_apps/<name>/main.c` |

## Build

```
sudo apt install gcc-arm-none-eabi
make c-apps              # builds build/<name>.uf2 for every c_apps/<name>/
```

The C build uses:
- `-mcpu=cortex-m33 -mthumb -mfloat-abi=soft`
- `-ffreestanding -fno-builtin -nostdlib` (no host libc)
- `-ffunction-sections -fdata-sections` + `--gc-sections` (drop unused)
- `-O2 -Wall -Wextra` and `-I c_bridge/include`

No newlib, no crt0, no `_init_array`. C starts at `main()`, called by our
`src/startup.S` after VTOR / RESETS / etc are set up. Your `main()` must
call `_c_runtime_init()` before touching any global / static so `.bss`
reads as zero.

## Hello world

```c
#include "rp_asm.h"

static uint32_t counter;   // in .bss, zeroed by _c_runtime_init

int main(void) {
    _c_runtime_init();

    xosc_init();
    pll_sys_150_mhz();
    pll_usb_48_mhz();
    clocks_init();
    gpio_led_init();
    uart0_init();
    clocks_post_pll_uart_baud_fixup();

    uart0_puts("hello from C\r\n");
    for (;;) {
        gpio_led_toggle();
        counter++;
        for (volatile int i = 0; i < 6250000; i++) {}
    }
}
```

## Image size

`hello_c.uf2` builds to **1004 bytes of `.text`** (+ 4 B `.bss` for the
counter). For comparison, the asm equivalent (`build/blinky.uf2`) is
728 bytes; the delta is the cost of `_c_runtime_init` + the `printf`-style
hex dump in the demo.

## What `_c_runtime_init` does

```asm
_c_runtime_init:
    ldr     r0, =__bss_start__
    ldr     r1, =__bss_end__
    movs    r2, #0
1:  cmp     r0, r1
    bhs     2f
    str     r2, [r0], #4
    b       1b
2:  bx      lr
```

That's it. No `.data` copy (we're SRAM-resident, .data is loaded by the
UF2 bootrom directly into RAM). No `__libc_init_array` (we don't
support C++ constructors). No newlib initialisation. If you need those,
you've out-grown ticktrace and want pico-sdk.

## asm_libc: the implicit-call layer

gcc emits calls to `memset` / `memcpy` / `memcmp` from idiomatic C code
even if you never `#include <string.h>`: large initializers, struct
copies, comparison of byte arrays. The asm versions are <100 bytes each
and word-stride where the alignment allows.

| Function | Path | Cycles |
| -------- | ---- | -----: |
| `memset` (aligned, n=64)  | word stride | ~50 |
| `memcpy` (aligned, n=64)  | word stride | ~70 |
| `memcmp` (any alignment)  | byte stride | ~5*n + 5 |

If you need `strlen`, `strcpy`, etc., add them to `c_bridge/asm_libc.S`
the same way.

## Calling drivers from C

Every public asm driver function is declared in `c_bridge/include/rp_asm.h`
as `extern "C"`. They follow AAPCS so C call sites work directly:

```c
gpio_set_function(25, 5);      // GPIO_FUNC_SIO = 5
uart_putc_blocking(0, 'A');
uint32_t cycles = dwt_cycles_since(t0);
```

For the scheduler, `task_create` takes a function pointer; declare your
handler as `void task_fn(void)` and pass it directly:

```c
static void my_task(void) {
    gpio_toggle(25);
}

int main(void) {
    sched_init();
    task_create(0, my_task, 0x00);
    task_post(0);
    sched_run();      // noreturn
}
```

The `noreturn` attribute on `sched_run` in the header lets gcc drop the
return-to-main path entirely.

## T1 tests

`tests/unicorn/test_c_bridge.py` (8 cases):

- `memset` zeroes, replicates the byte across the buffer, handles
  unaligned counts.
- `memcpy` word-aligned path; byte fallback for unaligned count.
- `memcmp` returns 0 when equal; the signed difference at the first
  mismatch otherwise.
- `_c_runtime_init` zeroes the `__bss_start__..__bss_end__` range.

## Limitations

- No malloc / free. Some C libs assume `_sbrk`; TinyUSB doesn't, so it's
  fine. If you need a heap, add a 30-line bump allocator.
- No floating-point library. `-mfloat-abi=soft` is set; if you really
  need float, switch to `softfp` and link `libgcc.a` for the helpers.
- No `assert`. Define `NDEBUG` or your own `assert` macro.
- No `errno`. Define one yourself or `#define errno (*((int*)0x20000000))`
  if you don't care (you probably don't).

## Picking C vs asm

The C bridge does not replace the asm core. It's for when you want to
write *application logic* in C while keeping the drivers cycle-tuned.

Use C for: protocol handlers, parsers, application state machines, code
that humans will read more than once.

Use asm for: drivers, ISR top-halves, anything where you'd be unhappy if
the optimiser changed its mind.

See `docs/calling.md` for the full ABI contract that both languages obey.
