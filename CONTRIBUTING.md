# Contributing to ticktrace

Thanks for considering a contribution. ticktrace is a small, opinionated SDK with a high bar for what lands in `src/`: every cycle is accounted for, every byte is something the next reader can understand. This guide explains how to keep contributions inside that bar.

If you're new and looking for somewhere to start, look at the [open issues labeled `good first issue`](https://github.com/ticktrace-sdk/rp-asm/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) and the [open issues labeled `help wanted`](https://github.com/ticktrace-sdk/rp-asm/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22).


## Before you submit code

ticktrace is dual-licensed (AGPL-3.0-or-later + commercial). For Amken LLC to be able to ship contributions under both licenses, every PR needs a sign-off from its author. We use a lightweight **CLA + DCO** model:

1. **DCO sign-off on every commit.** Add `Signed-off-by: Your Name <your@email>` as the last line of every commit message. `git commit -s` adds this automatically. This is the [Developer Certificate of Origin](https://developercertificate.org/) and certifies you wrote the code (or have permission to contribute it).

2. **CLA for non-trivial contributions.** If your PR is more than a typo fix or a docstring edit (roughly: anything that adds or changes code in `src/`, `examples/`, `tools/`, or `tests/`), we'll ask you to sign a one-page Contributor License Agreement before merging. The CLA grants Amken LLC the right to also distribute your contribution under the commercial license. It does **not** transfer your copyright — you retain that. We'll send a link to a digital-signature flow when the PR is ready to merge.

Trivial fixes (typos, broken links, comment clarifications) only need the DCO sign-off, not the CLA.

If either requirement is a blocker for you, open an issue describing the contribution and we'll figure out a workable path together.


## How to add a peripheral driver

Drivers live in `src/<peripheral>.S` and register-map headers in `include/<peripheral>.inc`. The drill:

1. **Register-map header first.** `include/<peripheral>.inc` carries `.equ` constants for every base address, register offset, bitfield mask, and bitfield shift you'll touch. One line per symbol. The comment next to each constant cites the datasheet section so the next reader can verify it.

2. **Driver source.** `src/<peripheral>.S` starts with the canonical SPDX + copyright header from [`SOURCE-HEADER-TEMPLATE.md`](SOURCE-HEADER-TEMPLATE.md) (use the assembly variant), then a block comment listing the **public API** with its AAPCS argument convention and cycle costs for the hot paths. Each public function is `.global`-marked and follows AAPCS strictly: arguments in `r0`-`r3`, return in `r0`, callee-saves (`r4`-`r11`) preserved, stack 8-byte aligned at call boundaries.

3. **Use atomic aliases for every multi-bit write.** RP2350 maps each peripheral register at four addresses: base, base+`0x1000` (XOR), base+`0x2000` (SET), base+`0x3000` (CLR). One `STR` to the SET/CLR alias atomically modifies the bits; never use a read-modify-write `LDR`/`ORR`/`STR` sequence to a peripheral register unless you have a specific reason and a comment explaining it.

4. **Pad isolation.** RP2350 pads reset with `ISO=1`. Any driver that touches a GPIO must clear `ISO|OD` via the PADS_BANK0 CLR alias before driving the pin. See `src/gpio.S` for the pattern.

5. **No undocumented cycle costs in hot paths.** For ISR handlers, tight inner loops, and any function on a deterministic-timing path, add a comment line counting cycles next to the instructions. See `src/uart.S` for the convention.

6. **Wire it into the build.** Append your driver's source path to the `DRIVER_SRC` list in `Makefile`. The format is a single line with a comment naming the milestone or peripheral group — match the existing pattern.

7. **Add an example.** Every driver gets at least one self-contained example in `examples/<peripheral>_*_demo.S` that:
   - Documents required hardware wiring at the top of the file (jumpers, voltages, scope hookup).
   - Calls the driver through its public API only.
   - Reports success/failure on UART0 and/or via the LED.

8. **Write a T1 test.** Every public driver function gets at least one register-trace assertion in `tests/unicorn/test_<peripheral>.py`. The pattern: invoke the function via `harness.RP2350Sim.call_function()`, then assert on the exact MMIO addresses and values the driver writes. See `tests/unicorn/test_gpio.py` for the canonical template.

9. **Document the driver.** Add `docs/<peripheral>.md` covering the boot/init sequence, the calling convention, anything erratum-related, and at least one worked example. The docs feed both the on-repo `docs/` tree and the [cookbook](https://www.ticktrace.io/cookbook) on ticktrace.io.

10. **Show it running on real silicon.** A driver PR is not complete until the contributor has demonstrated it working on a physical Pico 2 (or other RP2350 board). Acceptable proof, in any of these forms, attached to the PR description:
    - A short screencast / video clip showing the example UF2 driving the peripheral (the LED blinking, the OLED showing text, the motor spinning).
    - A photo of the wired board with the relevant scope / logic-analyser / serial-terminal output visible.
    - For peripherals where the visible artefact is structured data (UART, USB CDC), a serial-terminal log snippet with the wiring photo separately.
    Emulator-only verification (T1 / T2 / T3) is necessary but not sufficient — every driver in the SDK has had hardware bring-up before merge, and every new driver continues that bar. If you don't have the hardware to verify a specific peripheral, open the PR as a draft and tag it with `needs hardware verification`; we'll coordinate getting it onto a board.

A driver PR that hits all ten of these gets merged fast. Skipping any of them means we'll come back with comments asking you to fill it in.


## How to add an example

Examples are the most welcome contribution category because they expand what users can build with the SDK without changing any drivers. To add one:

1. Put it in `examples/<descriptive_name>_demo.S`. The naming convention is `<peripheral>_<scenario>_demo.S` (e.g. `i2c_eeprom_demo.S`, `pwm_servo_demo.S`).
2. Start the file with the canonical SPDX + copyright header from [`SOURCE-HEADER-TEMPLATE.md`](SOURCE-HEADER-TEMPLATE.md). The assembly variant is what `.S` files use; the short form is fine for tiny examples.
3. Document the hardware wiring required at the top of the file. Include voltages, pin numbers, and any jumpers or external parts the user needs.
4. The example should drive a single concept clearly. If you need three concepts, write three examples.
5. The Makefile auto-discovers `examples/*.S` — no Makefile edit needed.
6. **Verify on real hardware before opening the PR.** Examples that haven't been driven on a Pico 2 are easy to write and hard to trust. The PR description should include either a short video / GIF of the example running, or a photo of the wired board with the relevant output (LED, serial terminal, OLED, scope trace) visible. Emulator-only verification is not enough for examples.

`make build/<your_example>.uf2` should produce a working UF2 you can drag onto a Pico 2 in BOOTSEL mode.


## How to add a cookbook recipe

Cookbook entries are docs that show "how to do X with the SDK" for tasks that span multiple drivers (e.g. "drive a stepper motor via PWM + GPIO"). They live in `docs/<recipe-slug>.md` and render automatically on [ticktrace.io/cookbook](https://www.ticktrace.io/cookbook).

A good cookbook recipe has:

- One concrete user goal in the title.
- A worked code example, complete enough to copy-paste and run.
- Cycle / size accounting where it matters.
- A short "gotchas" section at the end.

Match the voice of the existing cookbook entries — terse, technical, no marketing.


## How to file a bug

Open an issue describing:

1. **What you ran.** The exact `make` target, the Docker image tag if relevant, the SDK commit you're on.
2. **What you expected.** Behaviour the docs or this README led you to expect.
3. **What happened instead.** Build error, runtime hang, wrong output. Paste verbatim text where useful.
4. **Minimal reproducer.** The smallest source file that triggers the bug. If hardware-dependent, the board variant and any wiring.

Bugs against the test pyramid (T1/T2/T3 false-pass or false-fail) are especially valuable — assertion-level regressions are how we keep the silicon-verified claim honest.


## Code style

- **Every source file starts with the SPDX + copyright header from [`SOURCE-HEADER-TEMPLATE.md`](SOURCE-HEADER-TEMPLATE.md)**, using the variant that matches the file type (C-family, assembly, or `#`-comment). The `SPDX-License-Identifier: AGPL-3.0-or-later` line is mandatory and must not be modified or reformatted — license scanners parse it literally.
- `@` for line comments (ARM convention), `/* ... */` for multi-line block comments at file top.
- Column-aligned argument-convention comments: see the public-API block at the top of `src/uart.S`.
- 4-space indentation in `.S` files; no tabs.
- Function names are `<peripheral>_<verb>_<modifier>`, lowercase, underscore-separated (`uart_putc_blocking`, `gpio_set_out`).
- Public symbols get `.global`. Internal helpers don't.
- One concept per function; if the function comment needs the word "also", split it.
- `git commit -s` for the DCO sign-off.

`make` and `make test` should be green before opening the PR. The full T1+T2+test-tools suite runs in about 90 seconds locally; the `ghcr.io/ticktrace-sdk/sdk:full` Docker image bundles everything you need to reproduce it on any host.


## PR process

1. Fork the repo, branch from `main`.
2. One concern per PR. A driver + an example for it is fine; a driver + an unrelated refactor is not.
3. PR title is imperative and specific (`Add I2C eeprom driver`, not `i2c stuff`).
4. PR description references the issue if one exists, lists what hardware you tested on (the board variant + any external parts), attaches hardware-verification proof for driver / example PRs as required above, and notes any deviations from the conventions in this file with a reason.
5. CI must be green before review.
6. We'll send the CLA link after first review if the PR is non-trivial.

Expect a turnaround of a few business days for a first response. If we haven't replied in a week, ping the PR thread.


## Where to ask

- For technical questions about how the SDK works: open a [discussion](https://github.com/ticktrace-sdk/rp-asm/discussions).
- For commercial-license / partnership questions: <licensing@ticktrace.io>.
- For bugs and feature requests: open an [issue](https://github.com/ticktrace-sdk/rp-asm/issues).

Thanks for reading this far. The bar is high because the project's whole pitch is "every byte is a line you can read" — contributions that uphold that pitch are what keep the SDK worth shipping.
