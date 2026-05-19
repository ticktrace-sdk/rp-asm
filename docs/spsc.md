# SPSC byte queue

Lock-free single-producer, single-consumer byte queue. The canonical
use is "hardware ISR pushes; soft task pops"; the SPSC role guarantees
no locks are needed.

Driver: `src/spsc.S`. Defs + macro: `include/spsc.inc`.

## API

```
spsc_byte_push(r0=q, r1=byte) -> r0       1 = pushed, 0 = full
spsc_byte_pop(r0=q) -> r0                 byte 0..255, or -1 if empty
spsc_byte_count(r0=q) -> r0               bytes currently buffered
spsc_reset(r0=q)                          head = tail = 0
```

Cycle costs:

| Function          | Cycles (Cortex-M33 from SRAM, no contention) |
| ----------------- | -------------------------------------------- |
| `spsc_byte_push`  | ~14 (push/pop r4 + 4 loads + cmp + strb + str) |
| `spsc_byte_pop`   | ~10                                          |
| `spsc_byte_count` | ~8                                           |

## Declaring a queue

Use the `M_SPSC_BYTE_QUEUE` macro. It takes the queue name and the
log-base-2 of the buffer size (size must be a power of 2 for cheap
mask-based wraparound):

```asm
    .include "spsc.inc"

    @ A 64-byte buffer.  Capacity is 63 (one slot reserved to
    @ distinguish empty from full).
    M_SPSC_BYTE_QUEUE  uart_rx_q, 6
```

The macro emits the queue header + buffer in the `.data` section
(initialised because `mask` is non-zero). The label `uart_rx_q` points
to the struct header.

## Quick start: UART RX → soft task

```asm
    M_SPSC_BYTE_QUEUE  uart_rx_q, 6

    @ ----- hardware ISR --------------------------------------------------
uart0_rx_isr:
    push    {lr}
    @ Read every available byte and push.  Spec'd: PL011 RXIM clears
    @ when the FIFO drains below threshold, so we drain everything.
1:  movs    r0, #0
    bl      uart_is_readable
    cmp     r0, #0
    beq     2f
    movs    r0, #0
    bl      uart_getc_blocking      @ returns byte in r0
    push    {r0}
    ldr     r0, =uart_rx_q
    pop     {r1}
    bl      spsc_byte_push          @ ignore overflow for the demo
    b       1b

2:  @ Acknowledge IRQ + post the soft consumer task
    movs    r0, #0
    movs    r1, #(1 << 4)           @ RXMIS bit
    bl      uart_acknowledge_irq
    movs    r0, #T_RX_CONSUMER
    bl      task_post
    pop     {pc}

    @ ----- soft task -----------------------------------------------------
t_rx_consumer:
    push    {lr}
1:  ldr     r0, =uart_rx_q
    bl      spsc_byte_pop
    cmp     r0, #0
    blt     2f                      @ -1 = empty, we're done
    @ ... process byte r0 ...
    b       1b
2:  pop     {pc}
```

## When you can NOT use SPSC

- **Two producers.** If two ISRs both push into the same queue, wrap
  pushes in `critical_enter_basepri` / `critical_exit_basepri`, or use
  per-producer queues.
- **Two consumers.** Same logic; wrap pops.
- **Cross-core.** Cortex-M33 SPSC inside one core works without DMB.
  Across the two RP2350 M33 cores, you'd need a DMB after the data
  write and before the head publish (M6 / dual-core territory).

## Layout

```
+0   head    uint32_t   producer write index (only ISR writes)
+4   tail    uint32_t   consumer read index   (only task writes)
+8   mask    uint32_t   size_pow2 - 1
+12  pad     uint32_t   reserved
+16  data    uint8_t[size_pow2]
```

Capacity is `size - 1` (one slot reserved to distinguish empty from
full; the standard SPSC trick).

## T1 tests

`tests/unicorn/test_spsc.py` (8 cases):

- Round-trip a single byte
- Pop on empty returns -1
- FIFO order over 5 pushes
- 16th push (capacity 15) returns 0; head doesn't advance
- Wraparound works (push 10, pop 8, push 8 more, pop all 10 in order)
- Count matches actual size after mixed push/pop
- `spsc_reset` zeroes head + tail
- Wide `r1` (e.g. `0xDEADBE5A`) only stores the low byte
