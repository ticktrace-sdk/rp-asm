# Per-task DWT cycle accounting

Opt-in cycle-accounting layer on top of `src/sched.S`. When you create
a task with `task_create_traced` instead of `task_create`, a tiny
trampoline samples `DWT.CYCCNT` around every invocation and updates
three per-task counters.

Driver: `src/sched_stats.S`. Defs in `include/sched.inc`.

If your application never calls `task_create_traced`, the entire
sched_stats module is dropped by `--gc-sections` and you pay zero bytes.

## API

```
task_create_traced(r0=id, r1=fn, r2=prio)    Like task_create, but routes
                                             through _task_tramp_<id>.
task_stats_total(r0=id) -> r0                Cycles_total (sum across all calls)
task_stats_invocations(r0=id) -> r0          Number of times task has run
task_stats_max(r0=id) -> r0                  Worst-case single-call cycles
task_stats_reset(r0=id)                      Zero counters; preserve fn
task_stats_reset_all                         Zero counters for every slot
```

The global `task_stats[]` array (8 × 16-byte slots, in `.data`) is
exposed for tools that want to dump everything at once.

## How much it costs

Per traced invocation, on top of the task body's own runtime:

| Step                              | Cycles |
| --------------------------------- | -----: |
| Trampoline prologue (`push`)      | 2      |
| Read CYCCNT (t0)                  | 2      |
| `ldr` user fn + `blx`             | 4      |
| Read CYCCNT (t1)                  | 2      |
| Update cycles_total               | 4      |
| Update invocations                | 4      |
| Update max_cycles                 | ~4     |
| Trampoline epilogue (`pop`)       | 3      |
| **Per-call overhead**             | **~25 cycles** |

That's the entire price you pay for live cycle accounting.

## Quick start

```asm
    .equ T_BLINK, 0

    bl      sched_init

    @ Install with tracing
    movs    r0, #T_BLINK
    ldr     r1, =blink_task_body
    movs    r2, #0x00
    bl      task_create_traced

    @ ... post / sched_run as usual ...

    @ Later: dump stats
    movs    r0, #T_BLINK
    bl      task_stats_total            @ r0 = cycles consumed
    movs    r0, #T_BLINK
    bl      task_stats_max              @ r0 = worst-case
```

## Use cases

1. **Find your hot task.** Run for 10 s, dump
   `task_stats_total(id)` for every task, compare. The one with the
   biggest number is where your cycles are going.

2. **Catch a runaway worst-case.** A task that normally runs in 100
   cycles but occasionally spikes to 50 000 shows up immediately in
   `task_stats_max`. The total/invocations average would hide it.

3. **Verify a refactor.** Before: `total = X`. After: `total = X / 2`.
   You know your optimisation worked.

4. **Production telemetry.** Every minute, push the stats over UART
   or ITM (cheaper than logs). Reset, repeat. You now have a real-time
   dashboard of task health.

## Caveats

- `task_stats_reset_all` does NOT zero the fn slots. To fully clear a
  slot before re-registering a different fn, just call
  `task_create_traced` again; it overwrites the fn pointer.
- The counters are 32-bit. `cycles_total` wraps at ~28.6 s of
  continuous busy time at 150 MHz; for long-running profiling, sample
  + reset periodically.
- Mixing `task_create` and `task_create_traced` works (trace what you
  care about, skip the overhead elsewhere); they share the same task
  table and NVIC slots.

## T1 tests

`tests/unicorn/test_sched_stats.py` (8 cases):

- `task_create_traced` stores the user fn (Thumb-encoded) in
  `task_stats[id].fn`.
- A direct call to `_task_tramp_0` updates total / invocations /
  max_cycles to the expected DWT delta (harness mocks CYCCNT to
  advance by a fixed step per read).
- Two invocations with different deltas accumulate `total` and keep
  the worst case in `max_cycles`.
- All three getters return the stored values.
- `task_stats_reset(id)` zeroes counters but keeps fn.
- `task_stats_reset_all` zeroes counters across all 8 slots, keeps
  every fn intact.
