# Scheduler: NVIC-priority kernel 
A 200-LOC asm scheduler that uses the Cortex-M33 NVIC as its dispatch
engine. 

Driver: `src/sched.S`. Defs: `include/sched.inc`.


**Every task is an NVIC interrupt handler.** Posting a task is one
`STR` to NVIC_ISPR; the hardware tail-chains into the highest-priority
pending task, runs it to completion, and re-enters WFI in thread mode
when nothing is pending.

## Why this is fast

| Operation              | Cycles | Comparison                                    |
| ---------------------- | -----: | --------------------------------------------- |
| `task_post`            | **5**  | FreeRTOS `xQueueSendFromISR`: ~150            |
| `task_post`-to-task entry | **17** | (5 cycle post + 12 cycle hardware IRQ entry) |
| Context switch overhead | **0** | All tasks share MSP; no save/restore         |
| Per-task RAM overhead  | **~16 B** | (vector + IPR byte + bookkeeping); FreeRTOS: ≥64 B stack |
| Mutex/semaphore for same-prio | **none needed** | Run-to-completion eliminates the race |

## API

```
sched_init                                  Clear pending, set SEVONPEND
task_create(r0=id, r1=fn, r2=prio)         Install fn @ vector, set NVIC prio, enable
task_post(r0=id)                            One STR to NVIC_ISPR  (5 cycles)
task_post_n(r0=mask)                        Post multiple tasks in ONE STR (6 cycles)
task_clear(r0=id)                           Cancel a pending post (NVIC_ICPR)
sched_run                                   cpsie i; loop { wfi }  (never returns)

@ Critical sections
critical_enter() -> r0                      MRS PRIMASK; CPSID i   (3 cycles)
critical_exit(r0)                           Restore PRIMASK
critical_enter_basepri(prio) -> r0          Mask <= `prio`; higher-prio tasks still preempt
critical_exit_basepri(saved)                Restore BASEPRI
```

`id` is 0..7 (8 task slots). Lower `prio` numeric = higher priority.
`prio` byte uses the top NVIC_PRIO_BITS bits the chip implements; RP2350
typically implements 2–3 bits, so 0x00 / 0x40 / 0x80 / 0xC0 give you
four bands.

### task_post_n: batch posting

`task_post_n(mask)` posts every task whose bit is set in `mask`, in a
single store. Default config (8 task slots starting at IRQ 48, all in
NVIC bank 1) is what makes this a single STR; if you change
`SCHED_BASE_IRQ` such that the slots straddle two NVIC banks, this
function still works but the optimisation is lost.

```asm
    @ Wake the LED, the tick task, and the DMA-completion task at once
    movs    r0, #((1 << T_BLINK) | (1 << T_TICK) | (1 << T_DMA_DONE))
    bl      task_post_n
```

### BASEPRI critical sections

Use these instead of `critical_enter` when you need to protect shared
state from medium/low-priority tasks but want the highest-priority task
to keep preempting (e.g. a real-time control loop that must not slip).

```asm
    @ Protect a shared FSM step from tasks at prio 0x40 and below.
    @ Tasks at prio 0x00 can still preempt; that's the point.
    movs    r0, #0x40
    bl      critical_enter_basepri
    push    {r0}                @ stash previous BASEPRI

    @ ... touch shared state ...

    pop     {r0}
    bl      critical_exit_basepri
```

`critical_enter` (PRIMASK) is heavier-handed: it masks *everything*
including HardFault. Use it for the very shortest critical sections only,
or where simplicity wins over latency.

## Task body contract

- AAPCS: `push {r4, lr}` if you touch `r4`-`r11` or call anything;
  return with `pop {r4, pc}` or `bx lr`.
- **No blocking.** Tasks run to completion. To "wait", arm a TIMER0
  alarm whose ISR posts you back.
- Tasks share the main stack. Recursion across `task_post → task body`
  consumes the same stack; budget conservatively (256 B is plenty for
  typical work).
- A task at the same priority as the currently-running task waits
  until the current one returns; there's no same-priority preemption.
  Different priority *does* preempt (NVIC's normal behaviour).

## The "no sleep" idiom

You don't `sleep_ms(N)`. You arm a TIMER alarm whose ISR posts you
back. Like this:

```asm
@ Schedule T_NEXT to run 100 ms from now.
wait_100ms_then_run:
    bl      time_us_32
    ldr     r2, =100000
    add     r2, r2, r0          @ target = now + 100000 µs
    movs    r0, #0              @ timer 0
    movs    r1, #2              @ alarm 2 (dedicated to T_NEXT)
    movs    r3, #0
    bl      alarm_set
    @ When alarm 2 fires, its hardware ISR calls task_post(T_NEXT).
    bx      lr
```

This forces an event-driven shape on your code, which is a feature, not
a limit; the resulting state machines are dramatically easier to
debug than "what's that task blocked on right now."

## Inter-task communication

Three patterns, ordered by complexity:

1. **Global variable.** Tasks at the same priority can't race, so
   simple `.word` globals are fine for one-byte / one-word state.

   ```asm
       .section .bss.shared, "aw", %nobits
       .align 2
   rx_byte: .word 0
   ```

2. **`critical_enter_basepri` / `critical_exit_basepri`.** For
   multi-word state across different priorities, when you want a
   specific high-priority task to keep preempting. PRIMASK variants
   exist for the rare case where you need to mask everything.

3. **Lock-free SPSC ring buffer**, shipped as `src/spsc.S` +
   `include/spsc.inc`. Declare a queue with the `M_SPSC_BYTE_QUEUE`
   macro:

   ```asm
       .include "spsc.inc"
       M_SPSC_BYTE_QUEUE  uart_rx_q, 6      @ 64-byte buffer
   ```

   Producer (typically a hardware ISR) calls `spsc_byte_push`;
   consumer (a soft task) calls `spsc_byte_pop`. No locks needed when
   used in the SPSC role; see `docs/spsc.md` for details.

## What the scheduler doesn't do

- **No task delete / dynamic create.** Slots are fixed at 8. Adjust
  `MAX_TASKS` in `sched.inc` if you need more (you'll burn more NVIC
  lines from `SCHED_BASE_IRQ`).
- **No timers, no events.** TIMER0 + the existing `alarm_*` functions
  cover the "schedule X for time T" need; the demo wires it up.
- **No watchdog kicking, no MPU partitioning, no power management.**
  Those are application-level concerns.
- **No priority inversion mitigation.** With pure run-to-completion and
  no shared resources requiring locks, you can't have priority
  inversion. If you add locks (don't), you'll need to.

## NVIC slot layout

Default uses RP2350 NVIC lines 48..55 for task slots. Datasheet rev 0.3
§3.2 reserves this range for "spare" lines not connected to hardware
peripherals. If your chip rev maps any of these, raise `SCHED_BASE_IRQ`
in `include/sched.inc`.

| Task ID | NVIC line | Default priority byte |
| ------- | --------- | --------------------- |
| 0       | 48        | application-defined   |
| 1       | 49        | application-defined   |
| 2       | 50        | application-defined   |
| 3       | 51        | application-defined   |
| 4       | 52        | application-defined   |
| 5       | 53        | application-defined   |
| 6       | 54        | application-defined   |
| 7       | 55        | application-defined   |

## Demo

`build/sched_demo.uf2` (~1.4 KB):
- T_BLINK @ prio 0x00 toggles GP25 every 100 ms (driven by TIMER0
  ALARM0 ISR which posts it).
- T_TICK @ prio 0x40 prints `tick\r\n` every 1 s (TIMER0 ALARM1).
- T_HEAVY @ prio 0x80 spins 10 000 cycles with GP24 high; visible on
  a logic analyser; preemption shows up as a notch in the GP24 pulse
  when T_BLINK arrives.

## T1 tests

`tests/unicorn/test_sched.py` (9 cases):

- `sched_init` sets SCB.SCR.SEVONPEND and clears pending bits for the
  task IRQ range (ICPR1 = 0x00FF0000).
- `task_create(id=2, fn=0x20001234, prio=0x80)` installs `fn|1` at
  `_vectors + (16+50)*4`, writes 0x80 to NVIC_IPR[50], sets NVIC_ISER1
  bit 18.
- `task_create(id=0, ...)` lands on NVIC line 48 (ISER1 bit 16).
- `task_post(0)` writes (1<<16) to NVIC_ISPR1.
- `task_post(7)` writes (1<<23) to NVIC_ISPR1.
- `task_post` is exactly one PPB store (proves the "every cycle
  matters" claim isn't drift).
- `task_clear(4)` writes (1<<20) to NVIC_ICPR1.
- `critical_enter` returns previous PRIMASK; `critical_exit` restores.

## Open work

- Statistics: cycles spent per task, average post-to-entry latency.
  Per-task accounting would need a thin wrapper that reads DWT.CYCCNT
  in a task prologue/epilogue.
- Multi-bank `task_post_n` (today it's one STR only because all 8
  slots fit in NVIC bank 1; if you raise `MAX_TASKS` past what one
  bank holds, the API needs to fan out to multiple STRs).

## Insprired by

- Rust RTIC- Real Time Interrupt driven Concurrency

