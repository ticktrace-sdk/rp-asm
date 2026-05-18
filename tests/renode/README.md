# T3 - Renode integration tests

Tier 3 of the ticktrace test stack runs the actual `build/blinky.elf` against
a synthesised RP2350 platform inside [Renode](https://renode.io). This is
the slowest tier (real CPU emulation, real PL011 model) and runs only on
demand or in the nightly CI job.

## What it covers

- The image actually executes from SRAM, including the IMAGE_DEF +
  vector-table layout the bootrom expects.
- `RESETS_RESET_DONE` polling spins out correctly when a model mirrors
  RESET <-> RESET_DONE (Renode's `Python.PythonPeripheral` does this).
- The PL011 driver in `src/uart.S` produces real ASCII bytes - the
  banner "ticktrace v0.1" appears on UART0.
- LED toggle is observed at the bus level (watchpoint hook on
  `SIO_GPIO_OUT_XOR = 0xD0000028`).

## Files

| File | Purpose |
| --- | --- |
| `rp2350.repl`  | Platform definition (CPU, memory, peripherals, stubs) |
| `blinky.resc`  | Loads `build/blinky.elf`, runs 1 simulated second, dumps state |
| `run.sh`       | CLI entry point - skips with rc=0 if Renode missing |

## Install Renode

The deb is the easiest path on Debian/Ubuntu:

```bash
ver=1.16.1
curl -sSL -o /tmp/renode.deb \
    https://github.com/renode/renode/releases/download/v${ver}/renode_${ver}_amd64.deb
sudo apt-get install -y /tmp/renode.deb
renode --version
```

Other distros: download the `linux-portable.tar.gz` from the same release
and extract anywhere; add the `renode` script to `$PATH`.

## Run

```bash
./tests/renode/run.sh         # builds blinky if missing, runs and asserts
make test-t3                  # same, via the umbrella Makefile target
```

If Renode isn't installed the runner exits 0 with a `SKIP:` line so CI
keeps moving.  If you want a hard failure on missing tooling, set
`STRICT_RENODE=1` in the environment (the runner doesn't honour this yet -
file an issue if you need it).

## Adding a new T3 test

1. Drop a fixture .S into `src/` (or wire up a test-only build target if
   it's outside the production firmware).
2. Add a `.resc` next to `blinky.resc` that loads it and asserts on the
   resulting bus traffic / UART output.
3. Extend `run.sh` (or factor it out) to invoke the new `.resc`.

## Known gaps in the platform model

- Only **one** Cortex-M33 core; the real RP2350 has dual M33 + dual
  Hazard3 RISC-V.
- No PIO state machines; `PIO0/1/2` regions are zero-on-read stubs.
- No DMA, USB, ADC, watchdog, TIMER1 model, RTC, SPI, I2C.
- SIO is a flat `MappedMemory`; the real per-core SIO has GPIO_IN,
  FIFO_ST, etc. that we don't synthesise.
- Bootrom is empty - tests must load the image directly via
  `sysbus LoadELF` and call `cpu0 VectorTableOffset` explicitly.

These will be filled in as later milestones (M3 PIO, M4 DMA, ...) need
them.
