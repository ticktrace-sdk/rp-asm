# TRNG (M5-J)

True random number generator, new on RP2350 (RP2040 had none). Built on an
ARM CryptoCell-312 RNG block: a ring-oscillator entropy source feeds a
192-bit Entropy Holding Register (EHR) which the firmware drains as six
32-bit words at a time.

Driver: `src/trng.S`. Defs: `include/trng.inc`. Base: `0x400f0000`.
RESETS bit: `25`.

## API

```
trng_init                            RESETS clear, enable random source
trng_get_random_word() -> r0         spin TRNG_VALID, read EHR_DATA0; rearm
trng_get_random_block(r0=dst, r1=words) fetch N words; handles rearming
```

`trng_get_random_word` is convenient but only returns one of the six EHR
words. To get the full 192-bit batch use `trng_get_random_block(buf, 6)`.

## Quick start

```asm
    bl      trng_init
    bl      trng_get_random_word    @ r0 = 32 fresh random bits
```

For larger blocks:

```asm
    ldr     r0, =buffer             @ dst
    movs    r1, #16                 @ words
    bl      trng_get_random_block   @ buffer now holds 64 bytes
```

## Throughput

Limited by entropy collection time, not by CPU. Expect ~tens of µs per
192-bit batch on real silicon. For high-volume use (TLS keygen, etc.) seed
a software CSPRNG from the TRNG and pull from that.

## Health checks

CryptoCell exposes online statistical tests in `TRNG_BIST_CNTR_*`. The
driver doesn't read them automatically; if your application is
security-sensitive, poll them and reject the output if BIST flags a
failure. Defer to the RP2350 datasheet §10 + CryptoCell-312 TRM for the
acceptance criteria.

## Build artefacts

- `build/trng_demo.uf2`: prints 8 random 32-bit words over UART.

## T1 tests

`tests/unicorn/test_adc_trng.py::test_trng_*` (2 cases):

- `trng_init` clears RESETS bit 25 and writes `1` to `RND_SOURCE_ENABLE`.
- `trng_get_random_word` polls `TRNG_VALID`, reads `EHR_DATA0`, and writes
  `1` to `RNG_ICR` to release the EHR for refill.
