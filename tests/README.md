# ticktrace test infrastructure

Four-tier strategy. Each tier catches a distinct class of bug; tier
selection is a tradeoff between fidelity and speed.

| Tier | Tool                 | Speed     | What it catches                                                |
| ---- | -------------------- | --------- | -------------------------------------------------------------- |
| T1   | Unicorn (Python)     | ~10 ms    | MMIO write order, register values, opcode encoding             |
| T2   | qemu-system-arm      | ~200 ms   | full ARMv8-M ISA, exception flow, semihosting                  |
| T3   | Renode               | ~1-5 s    | end-to-end firmware on a synthetic RP2350 platform             |
| T4   | real hardware (Pico 2)| seconds  | clock domain, USB enumeration, electrical (manual; **not yet wired in CI**) |

T1+T2 run on every push (`make test`). T3 runs nightly or on demand via
the GitHub Actions workflow. T4 is manual: drag `build/<name>_flash.uf2`
onto BOOTSEL. Real-silicon-only failure modes the lower tiers cannot
catch -- post-bootrom MSPLIM, RCP coprocessor state, RP2350-A2 USB
errata, `clk_peri`-gated `RESET_DONE` -- are documented in
[`docs/boot.md`](../docs/boot.md) and
[`docs/usb.md`](../docs/usb.md).

## Quick start

```bash
sudo apt install binutils-arm-none-eabi qemu-system-arm python3-venv
make pydeps    # one-shot: create .venv + install unicorn/pyelftools/pytest
make           # build the firmware (SRAM-resident, used by T1)
make test      # T1 + T2 (fast tier)
make test-t3   # T3 (Renode - skips cleanly if not installed)
make test-all  # everything
```

`make pydeps` writes a project-local `.venv` and pins versions via
`tests/unicorn/requirements.txt`.  `make test-*` prefers `.venv/bin/python`
if present and falls back to system `python3`.

The T3 install path lives in [tests/renode/README.md](renode/README.md).

## How each tier works

### T1 - Unicorn host harness

`tests/unicorn/harness.py` exposes `RP2350Sim`:

```python
sim = RP2350Sim()
sim.load_elf("build/blinky.elf")
sim.mock_resets_done()                            # auto-mirrors RESET <-> RESET_DONE
tx = sim.mock_uart0_tx()                          # captures bytes written to UART0 DR
sim.run_until_write(SIO_GPIO_OUT_XOR)
assert sim.writes[0].addr == RESETS_RESET_CLR
assert bytes(tx).startswith(b"ticktrace v0.1")
```



- Every MMIO transaction (read OR write) is recorded as an `MmioEvent`
  with `pc`, `addr`, `size`, `value`. Tests assert directly on the
  trace.
- `on_write(base, size, fn)` / `on_read(base, size, fn)` register
  user-defined region callbacks for modelling peripheral side effects.
- `run_until_pc(addr)`, `run_until_write(addr)`, `run_steps(n)` cover
  the three common stop conditions.

Limitations: no SysTick, no NVIC behaviour beyond basic exception entry;
timing is instruction-count, not cycle-accurate.  The harness also
**NOPs out a small set of M33-only instructions** at load time (`mrc /
mcrr p7` for the RCP coprocessor, `msr msplim`) -- Unicorn doesn't
model those, but they're required on real silicon and live in
`_reset`'s prologue (see [`docs/boot.md`](../docs/boot.md)).  Tests
should therefore consider the trace **after** the M33 prologue:
`test_v01_blinky.py` filters PPB writes (`SCB_VTOR`, `SCB_CPACR`) so
the first peripheral write asserted against is the `RESETS_RESET` clear.

### T2 - QEMU semihosting smoke

`tests/qemu/sanity.S` runs on the ARM MPS2-AN505 board (a generic
Cortex-M33 reference platform shipped with QEMU). It uses semihosting
to:

- print `ok\n` via `SYS_WRITE0` (op `0x04`)
- exit with status 0 via `SYS_EXIT_EXTENDED` (op `0x20`, 2-word block)

Fixture `.S` files in `tests/qemu/cases/` declare an expected stdout
substring on the second line:

```
@ EXPECT: arith ok
```

The pytest wrapper (`test_isa.py`) iterates over every case, runs it
through `run.sh`, and asserts on both the QEMU exit code and the EXPECT
substring.

This tier is intentionally **not** RP2350-specific: it tests the ISA,
not our peripherals. If a Thumb-2 instruction encoding regresses or
QEMU's M33 model breaks across versions, T2 catches it.

### T3 - Renode integration

A real Cortex-M33 emulator with a real PL011 model. We synthesize a
minimal RP2350 platform in `tests/renode/rp2350.repl`:

- 512 KiB SRAM at `0x20000000`
- PL011 UART0 at `0x40070000` (analyzer-attached)
- RESETS at `0x40020000` with auto-mirroring `RESET_DONE`
- Stubs for IO_BANK0, PADS_BANK0, TIMER0/1, PIO0/1/2 so stray accesses
  log instead of bus-faulting
- Flat MappedMemory for SIO so the bus monitor can watchpoint
  `SIO_GPIO_OUT_XOR` and tally LED toggles

`blinky.resc` loads the ELF, runs for 1 simulated second, dumps the
UART history, and the runner asserts on banner presence + at least 4
LED toggles.

### T4 - real hardware

Manual.  Use the flash-resident UF2 variants (see
[`docs/boot.md`](../docs/boot.md) -- SRAM-resident does not run
reliably on RP2350-A2 silicon):

```
make build/blinky_flash.uf2            # 150 MHz blinky + UART banner
make build/diag_flash.uf2              # stage-blinker for bisecting boot hangs
make build/usb_cdc_echo_demo_flash.uf2 # CDC echo on /dev/ttyACM0
```


## Adding a new test

### A new T1 trace assertion

1. Identify the exact MMIO address(es) and value(s) you expect the
   firmware to emit.
2. In a new `tests/unicorn/test_<feature>.py`:
   ```python
   from harness import RP2350Sim
   def test_my_feature():
       sim = RP2350Sim()
       sim.load_elf("build/blinky.elf")
       sim.mock_resets_done()                # if your code spins on RESET_DONE
       sim.run_until_write(MY_REGISTER)
       assert sim.writes[-1].value == EXPECTED
   ```
3. `make test-t1` to verify locally.

### A new T2 fixture

1. Create `tests/qemu/cases/<name>.S`:
   ```
   @ EXPECT: <substring you'll print on success>
   @ ... vector table + _start ...
   ```
2. Use the semihosting helpers from `sanity.S` for output / exit.
3. `make test-t2`. The pytest wrapper auto-discovers it.

### A new T3 platform feature

If you add a peripheral driver to `src/`:

1. Extend `tests/renode/rp2350.repl` with a `Python.PythonPeripheral`
   stub at the right address (size `0x4000` covers the four atomic
   alias windows).
2. If a real Renode model exists for the peripheral (see
   `/opt/renode/scripts/single-node/*.resc` for examples), prefer that
   over a stub.
3. Either extend `blinky.resc` to assert on the new behaviour, or add
   a new `.resc` and tweak `run.sh`.

## CI

`.github/workflows/test.yml` defines two jobs:

- `fast` - runs `make test` on every push and PR.
- `slow` - runs `make test-t3` on a nightly cron and on
  `workflow_dispatch`.

Both install the toolchain via apt + pip; T3 additionally fetches the
Renode .deb from the upstream GitHub release.
