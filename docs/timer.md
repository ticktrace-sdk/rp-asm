# TIMER0 / TIMER1 / SysTick

This document covers the RP2350 wall-clock timers and the Cortex-M33
SysTick reload counter, as implemented by `src/timer.S`, `src/systick.S`,
and the NVIC helpers in `src/nvic.S`.

## Block layout

```
+-------------+     1 MHz tick (set up by tick_init in M2)
|   TICKS     +------+----------+
+-------------+      |          |
                     v          v
                 +-------+   +-------+
                 |TIMER0 |   |TIMER1 |     0x400b0000 / 0x400b8000
                 |       |   |       |     64-bit us counter, 4 alarms each
                 +---+---+   +---+---+
                     |           |
                     +---> NVIC IRQs 0..3 (TIMER0_IRQ_0..3)
                                 +---> NVIC IRQs 4..7 (TIMER1_IRQ_0..3)
```

```
SysTick (Cortex-M33 SCS)             0xE000E010..0xE000E01C
  CSR  ENABLE / TICKINT / CLKSOURCE
  RVR  reload value (24 bits)
  CVR  current value (24 bits)
  CALIB calibration (RO)

  -> SysTick exception (vector index 15)
```

## 64-bit read protocol

The TIMER0/TIMER1 counters are 64-bit, but the AHB is 32 bits wide.  To get
a coherent snapshot, the hardware exposes a *read latch*:

| Offset | Name     | Behaviour                                               |
| ------ | -------- | ------------------------------------------------------- |
| 0x0c   | `TIMELR` | Reads the low half **and latches the high half** to TIMEHR. |
| 0x08   | `TIMEHR` | Reads the latched high half (must be read AFTER TIMELR). |
| 0x28   | `TIMERAWL`| Unsynchronised low half (no latch).                    |
| 0x24   | `TIMERAWH`| Unsynchronised high half (no latch).                   |

`time_us_64` follows the latch protocol; `time_us_32` uses TIMERAWL since
a 32-bit-only read can't tear.

```
time_us_64:                        @ ~7 cycles
    ldr     r2, =TIMER0_BASE
    ldr     r0, [r2, #0x0c]        @ TIMELR (latches HI)
    ldr     r1, [r2, #0x08]        @ TIMEHR
    bx      lr
```

If you read TIMEHR first, you'll see a stale snapshot when the low half
wraps between the two reads (~71 minutes apart, but if you happen to land
on it, your timestamp jumps forward by 2^32 us).

## Alarm compare-low-only quirk

ALARMn registers are 32 bits, and they compare against TIMELR (the *low*
half only).  This means:

* The maximum lookahead per re-arm is 2^32 us = 71 minutes.
* For longer waits the caller (or ISR) must rearm `n_remaining_us`
  later by reading time_us_64 and re-issuing alarm_set.
* Writing ALARMn auto-arms the corresponding ARMED bit.  To disarm,
  write 1 to that bit in ARMED (RW1C semantics).
* The IRQ flag (INTR) is W1C - clear it in the ISR before leaving.

```
alarm_set(timer_idx=0, alarm_idx=2, target_lo=0xDEADBEEF, target_hi=0)
    -> TIMER0_BASE + 0x18 = 0xDEADBEEF      (auto-arms ARMED.bit2)
    -> TIMER0_BASE + 0x34 = (1<<2)          (W1C any prior INTR.bit2)
```

## NVIC line table

| Line | Name           | Source                  |
| ---- | -------------- | ----------------------- |
| 0    | TIMER0_IRQ_0   | TIMER0 ALARM0           |
| 1    | TIMER0_IRQ_1   | TIMER0 ALARM1           |
| 2    | TIMER0_IRQ_2   | TIMER0 ALARM2           |
| 3    | TIMER0_IRQ_3   | TIMER0 ALARM3           |
| 4    | TIMER1_IRQ_0   | TIMER1 ALARM0           |
| 5    | TIMER1_IRQ_1   | TIMER1 ALARM1           |
| 6    | TIMER1_IRQ_2   | TIMER1 ALARM2           |
| 7    | TIMER1_IRQ_3   | TIMER1 ALARM3           |

Vector-table location: the `_vectors` table from `src/startup.S` lives at
the start of SRAM (0x20000000) and is writable.  `nvic_install_handler`
patches it directly via `*VTOR + 0x40 + irq_num*4`; no copy is required.

```
nvic_install_handler(irq_num, handler):
    *(*(SCB_VTOR) + 0x40 + irq_num*4) = handler | 1
```

The Thumb bit is OR'd in unconditionally so callers can pass either
`&handler` or `&handler + 1`.

The two timer blocks must be brought out of reset before use.  M2's
startup did not touch RESETS bits 23 (timer0) or 24 (timer1); call
`timer_init` (alias for `timer_resets_enable`) once at boot.  The 1 MHz
TICK input was already wired up by M2's `tick_init`.

## SysTick at 150 MHz cookbook

SysTick's reload register is 24 bits, so at the post-M2 clk_sys=150 MHz
the maximum period is `2^24 / 150e6 = 111.85 ms`.  For longer ticks set
`CSR.CLKSOURCE=0` to use the divided source (clk_sys/8 = 18.75 MHz);
maximum period then becomes ~895 ms.

| Period | RVR (CSR.CLKSOURCE=1, processor clock)        |
| ------ | --------------------------------------------- |
| 1 ms   | `150_000 - 1`                                 |
| 5 ms   | `750_000 - 1`                                 |
| 10 ms  | `1_500_000 - 1`                               |
| 100 ms | `15_000_000 - 1` (close to the 24-bit limit)  |

```
systick_start_periodic(150_000 - 1):    @ 1 ms tick
    SYST_CSR = 0
    SYST_RVR = 149_999
    SYST_CVR = 0                        @ any write clears
    SYST_CSR = ENABLE | TICKINT | CLKSOURCE
```

The handler must live at vector index 15 (SysTick is a system exception,
not an external IRQ, so `nvic_install_handler` does not apply - see
`examples/systick_demo.S` for the direct-VTOR-patch idiom).

## Cycle budgets (Cortex-M33, no wait states)

| Function                   | Cycles   | Notes                            |
| -------------------------- | -------- | -------------------------------- |
| `time_us_32`               | ~3       | 1 ldr + bx                       |
| `time_us_64`               | ~7       | latch protocol + 2 ldrs          |
| `delay_us(N)` (small N)    | 5/iter   | tight ldr/sub/cmp/blo loop       |
| `delay_ms(N)`              | 4 + delay_us(N*1000) cycles |       |
| `alarm_set`                | ~10      | INTR W1C + ALARMn store          |
| `alarm_cancel`             | ~6       | ARMED W1C                        |
| `alarm_clear_irq`          | ~6       | INTR W1C                         |
| `alarm_enable_irq`         | ~6       | INTE atomic SET                  |
| `systick_start_periodic`   | ~6       | 3 stores                         |
| `systick_stop`             | ~4       | 1 store                          |
| `systick_get_value`        | ~3       | 1 ldr                            |
| `nvic_enable_irq`          | ~6       | bitmask + indexed store          |
| `nvic_set_priority`        | ~7       | 1 byte store                     |
| `nvic_install_handler`     | ~6       | VTOR read + indexed store        |

## Example: 100 ms alarm-driven blink

See `examples/timer_alarm_demo.S`.  The full IRQ plumbing is:

```
1. timer_init                          @ release TIMER0/1 from reset
2. nvic_install_handler(0, alarm0_isr) @ patch vec[16]
3. alarm_enable_irq(0, 0)              @ INTE.ALARM0 = 1
4. nvic_enable_irq(0)                  @ NVIC line 0 unmask
5. alarm_set(0, 0, time_us_32() + 100_000, 0)
6. main: wfi forever; ISR re-arms.
```

## Datasheet notes / open questions

* Datasheet rev 0.3 (Aug 2024) sec 12.8 documents the TIMER block;
  RESETS bit positions for timer0/timer1 are 23/24 per sec 7.5.
* The "compare on low 32 bits only" behavior is mentioned in passing in
  sec 12.8.3.  The `ALARMx` text is not explicit that the comparator is
  32-bit-only - we infer it from the register width and the fact there's
  no separate ALARMxH register.
* NVIC line numbers 0..7 for the eight timer alarms are listed in sec 3.2
  of rev 0.3 (Table 3.1); this matches what we use here.
