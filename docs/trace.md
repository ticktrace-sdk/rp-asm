# Trace (CoreSight DWT/ITM/TPIU/ETM)

For T4 hardware debugging. Cortex-M33 ships with four CoreSight components
that together give you on-target cycle counting, printf-over-SWO, and full
instruction trace.

Driver: `src/trace.S`. Defs: `include/trace.inc`.

| Block | What it gives you                                       | Need a probe?                                   |
| ----- | ------------------------------------------------------- | ----------------------------------------------- |
| DWT   | `CYCCNT`: free-running 32-bit clk_sys counter           | No (firmware-only)                              |
| ITM   | 32 stimulus ports: `printf` into trace stream           | Yes (any SWD probe + SWO, e.g. picoprobe)       |
| TPIU  | Routes ITM/ETM bytes to SWO pin                         | Yes (same probe)                                |
| ETM   | Every executed instruction, branch packets, timestamps  | Yes (trace-capable probe, J-Trace, Lauterbach)  |

You don't have to use all of them. The most useful combo is **DWT + ITM**:
DWT for cycle-accurate timing in your firmware, ITM for streaming debug
output to your host without ever stalling on a 115200-baud UART.

## API at a glance

```
trace_init(r0=clk_sys_hz, r1=swo_baud)        one-shot: DWT + ITM + TPIU + ETM

@ DWT
dwt_init                                       DEMCR.TRCENA + CYCCNT
dwt_cycles_read() -> r0                        read CYCCNT
dwt_cycles_reset                               zero CYCCNT
dwt_cycles_since(r0=start) -> r0               (now - start) & 0xFFFFFFFF

@ ITM
itm_init                                       unlock, enable all 32 ports
itm_putc(r0=port, r1=byte)                     1-byte stimulus packet
itm_puts(r0=port, r1=str)                      null-terminated
itm_putw(r0=port, r1=word)                     32-bit stimulus packet

@ TPIU
tpiu_init_swo(r0=clk_hz, r1=swo_baud)          NRZ SWO at integer baud

@ ETM
etm_init_simple                                trace ID=2, trace everything
etm_disable                                    quiesce
```

## DWT: cycle counter without a probe

This needs zero external hardware. Once `dwt_init` runs, any code can
sample `CYCCNT` and time itself.

```asm
    bl      dwt_init                @ once, at startup

    @ Time a workload:
    bl      dwt_cycles_read         @ r0 = t0
    mov     r4, r0
    bl      my_thing
    mov     r0, r4
    bl      dwt_cycles_since        @ r0 = cycle count
```

`CYCCNT` is 32 bits. At 150 MHz it wraps in ~28.6 s, and
`dwt_cycles_since` handles wrap-around in unsigned subtract semantics,
so the maximum measurable window is ~28 s, beyond which you'll need to
sample twice or count overflow events through the `CPICNT` / `EXCCNT`
events DWT also exposes.

`examples/trace_demo.S` uses this to time a 1000-iteration loop:
expect 1000 × 3 cycles + a few of overhead = ~3010 cycles.

## ITM: printf-over-SWO

`itm_putc(port, byte)` produces one 1-byte ITM packet on the trace bus.
`itm_putw(port, word)` produces one 5-byte packet (1 header + 4 data) in
a single store. Either is faster than `uart0_putc`:

| Method                  | Cycles per byte | Bandwidth at 150 MHz |
| ----------------------- | --------------: | -------------------: |
| `uart0_putc_blocking` (115200 baud) | ~13000 (PL011 wait) | 115 kb/s |
| `itm_putc` (port not busy)          | ~8                | ~150 MB/s peak from CPU side; actual rate capped by SWO baud |
| `itm_putw` (one STR for 4 bytes)    | ~8                | 4× the bytes per packet header |

The SWO output bandwidth is bounded by the baud you chose in
`tpiu_init_swo`. At 2 MHz that's 200 kB/s on the wire: plenty for log
lines, not enough for full trace.

### ITM port conventions

There are 32 stimulus ports. Common choices:

| Port | Convention                                              |
| ---: | ------------------------------------------------------- |
| 0    | "printf": text/log output for the host to consume       |
| 1    | event markers: single-word "I just hit point X"         |
| 2–7  | per-subsystem channels (e.g. one per FSM state machine) |
| 31   | high-rate sample / profiling drops                      |

OpenOCD's `itm port 0 on` enables only port 0 by default; turn on the
others as needed.

## TPIU: getting SWO off the chip

`tpiu_init_swo(clk_sys_hz, swo_baud)` writes ACPR (`(clk/baud) - 1`),
sets the NRZ pin protocol, and disables the formatter. After that, ITM
packets and ETM packets get serialised onto the SWO output line.

### Baud math at clk_sys = 150 MHz

| swo_baud | ACPR | Actual rate | Error |
| -------: | ---: | ----------: | ----: |
| 6 MHz    | 24   | 6.0 MHz     | 0%    |
| 3 MHz    | 49   | 3.0 MHz     | 0%    |
| 2 MHz    | 74   | 2.0 MHz     | 0%    |
| 1 MHz    | 149  | 1.0 MHz     | 0%    |

Use the highest your probe and signal integrity will tolerate. Picoprobe
is comfortable at 2 MHz; SEGGER J-Link runs SWO at up to 100 MHz with a
proper trace cable.

### Pin routing on RP2350

The Cortex-M33 SWO signal needs to come out of a GPIO. RP2350's debug
pad mux exposes SWO as a GPIO function (datasheet §6.7). Pick a free
pin and either:

- Use `gpio_set_function(pin, GPIO_FUNC_TRACE_SWO)` (replace the literal
  with the value from your local datasheet; at time of writing,
  `include/trace.inc` doesn't pin it because the mux constant has been
  in flux across silicon revisions);

OR

- Configure pad routing via openocd's `rp2350.cfg` and let the probe
  drive the right mux.

`docs/trace.md` will pin a specific GPIO + funcsel once we've verified
on Pico 2 silicon. Until then `tpiu_init_swo` is configured for SWO
correctly on the *core* side; the *pad* routing is up to you.

## ETM: every instruction

`etm_init_simple` sets ETM to trace ID 2 and starts capturing every
executed instruction immediately. Without filters this generates a *lot*
of packets (easily 100+ MB/s) far beyond what SWO can carry. So
either:

- Use a parallel trace probe (TRACECLK + TRACEDATA[3:0]) with ETM
  ratematching, or
- Set up ETM address-range filters in `TRCVIIECTLR` etc. to only trace
  the function of interest. The driver leaves the filter regs at reset
  so the default behaviour is "trace everything"; extending the driver
  to take a `(start_addr, end_addr)` arg is a one-liner once you need
  it.

For most "what is my firmware doing right now" debugging, ITM is enough
and you should leave ETM off. Enable it only when you genuinely need
instruction-level trace.

## Host-side workflow with openocd + picoprobe

A picoprobe gives you SWD + SWO with one cable. Approximate workflow:

```sh
# 1. Flash the firmware (BOOTSEL + drag, or via openocd's rp2350-arm-s.cfg)
make build/trace_demo.uf2
# ... drag onto the BOOTSEL drive ...

# 2. Start openocd attached to the picoprobe
openocd -f interface/cmsis-dap.cfg \
        -f target/rp2350.cfg \
        -c "init" \
        -c "tpiu init" \
        -c "tpiu create rp2350.tpiu -dap rp2350.dap -ap-num 0" \
        -c "rp2350.tpiu configure -protocol uart -output - \
            -traceclk 150000000 -pin-freq 2000000" \
        -c "rp2350.tpiu enable" \
        -c "itm port 0 on"

# 3. Reset + run.  ITM port 0 prints arrive on openocd's stdout.
telnet localhost 4444
> reset run
```

Approximate openocd commands above; refer to your version's docs for
the exact incantation (the `tpiu` subsystem was reworked a few releases
ago and the option names shifted).

## T1 tests

`tests/unicorn/test_trace.py` (13 cases):

- `dwt_init` sets DEMCR.TRCENA, unlocks DWT_LAR, zeroes CYCCNT, enables
  CYCCNTENA.
- `dwt_cycles_read` returns whatever the harness preloaded into CYCCNT.
- `dwt_cycles_since` does unsigned subtract (including the wrap case).
- `itm_init` writes CS_LAR_UNLOCK to ITM_LAR, enables all 32 ports
  (TER=0xFFFFFFFF, TPR=0xFFFFFFFF), and configures TCR with
  ITMENA|SYNCENA|TXENA|SWOENA + TraceID 1.
- `itm_putc` spins on FIFOREADY, then STRB to STIM[port].
- `itm_putw` does one STR (word write).
- `itm_puts` walks the string until null.
- `tpiu_init_swo` writes ACPR = clk/baud - 1 (verified for 1 MHz and
  2 MHz from 150 MHz), SPPR=NRZ.
- `etm_init_simple` unlocks LAR+OSLAR, configures CONFIGR / TRACEIDR /
  VICTLR, and writes 1 to TRCPRGCTLR at the end.
- `etm_disable` writes 0 to TRCPRGCTLR and waits for IDLE.
- `trace_init` invokes the components in the right order
  (DEMCR before TPIU before ITM before ETM).

## Build artefacts

- `build/trace_demo.uf2`: initialises the trace stack, prints
  `"hello via ITM port 0"` on ITM port 0, measures a 1000-iteration
  busy loop with DWT, prints the cycle count over both UART and ITM
  port 1.

Expected on a real Pico 2:

```
$ openocd ... itm port 0 on
hello via ITM port 0

# and on UART0:
trace demo - clk_sys=150 MHz
1000 iters took 00000bd9 cycles      # ~3033 cycles
```

## Open work

- Pin a specific GPIO + funcsel for SWO once verified on real Pico 2
  silicon (`tpiu_init_swo` does the core-side work today; pad routing
  is currently the user's responsibility).
- `etm_init_with_range(start, end)`: ETM address-range filtering so
  ETM is usable over SWO.
- `dwt_set_watchpoint(addr, mask, fn)`: comparator-based break/trace
  on memory access. The DWT register layout in `include/trace.inc`
  already covers CYCCNT; comparator regs (`COMP0..3`, `MASK0..3`,
  `FUNCTION0..3`) just need the offsets and a thin setter.
