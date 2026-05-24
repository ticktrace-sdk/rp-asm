# Experimental: multi-chip support

This branch (`dev-rp2040-Support`) is **not for production use**. It exists to
track work-in-progress support for additional MCUs beyond the RP2350.

Production code lives on `main` and currently targets the **Raspberry Pi
RP2350** (Cortex-M33). Everything in `src/`, `examples/`, `docs/`, `tests/`,
and `tools/` on `main` is silicon-verified and shipped as part of tagged
releases.

## What's on this branch

### `chips/rp2040/` — RP2040 (Cortex-M0+)

Early "M2" milestone: clock-tree bring-up + UART banner + GPIO blinky on a
real Pico (RP2040). The image boots, prints, and toggles GP25 at ~250 ms.

| Status | Item |
|---|---|
| ✓ Works | `xosc`, `pll`, `clocks`, `watchdog` bring-up to clk_sys = 125 MHz |
| ✓ Works | `gpio` (M2 subset), `uart` (M2 subset) — driver code reused from main |
| ✓ Works | `boot2` passthrough + flash boot path |
| ✓ Works | Build artifacts: SRAM (`sram.ld`) and flash (`flash.ld`) link variants |
| ✓ Works | UF2 packer reports RP2040 family ID (0xE48BFF56) |
| ⚠ Partial | T1 unicorn tests — image-shape assertions only; no MMIO emulation yet |
| ✗ TBD | Top-level `Makefile` integration on this branch (build out-of-tree for now) |
| ✗ TBD | T2 / T3 test tiers |
| ✗ TBD | DMA, SPI, I²C, USB, PIO, multicore |
| ✗ TBD | Cookbook docs in `docs/` |

### `chips/rp2350/`

Not present on this branch. The RP2350 sources remain at their existing
`src/` location on `main`. A future "multi-chip restructure" would move
them under `chips/rp2350/` to match this layout — that work is staged
separately and intentionally out-of-scope here.

## Roadmap signal, not a release

- **No release tag** will be cut from this branch.
- **No CI** runs against it (the `.github/workflows/` jobs target `main`).
- **No support commitment** — APIs, file layout, and build steps may
  change without notice.
- Inquiries about RP2040 timeline: <licensing@ticktrace.io>.

## Related branches

- `dev-stm32c5-Support` — placeholder for STM32C5 (planned, no code yet)
