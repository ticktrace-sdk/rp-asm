@ =============================================================================
@ trng.inc - RP2350 TRNG (new for RP2350, ARM CryptoCell-312 derived)
@
@ Generates a 192-bit Entropy Holding Register (EHR) on demand from a ring-
@ oscillator-based source.  Firmware re-arms after every 6-word readout.
@ =============================================================================

    .equ TRNG_BASE,                0x400f0000
    .equ RESETS_trng,              25

    @ Register offsets
    .equ TRNG_RNG_IMR,             0x100
    .equ TRNG_RNG_ISR,             0x104
    .equ TRNG_RNG_ICR,             0x108
    .equ TRNG_CONFIG,              0x10C
    .equ TRNG_VALID,               0x110
    .equ TRNG_EHR_DATA0,           0x114
    .equ TRNG_EHR_DATA1,           0x118
    .equ TRNG_EHR_DATA2,           0x11C
    .equ TRNG_EHR_DATA3,           0x120
    .equ TRNG_EHR_DATA4,           0x124
    .equ TRNG_EHR_DATA5,           0x128
    .equ TRNG_RND_SOURCE_ENABLE,   0x12C
    .equ TRNG_SAMPLE_CNT1,         0x130
    .equ TRNG_AUTOCORR_STATISTIC,  0x134
    .equ TRNG_DEBUG_CONTROL,       0x138
    .equ TRNG_SW_RESET,            0x140
    .equ TRNG_BUSY,                0x1B8
    .equ TRNG_RST_BITS_COUNTER,    0x1BC
    .equ TRNG_VERSION,             0x1C0

    @ VALID bit
    .equ TRNG_VALID_EHR_VALID,     (1 << 0)

    @ ISR bit for EHR_VALID
    .equ TRNG_ISR_EHR_VALID,       (1 << 0)

    .equ TRNG_EHR_WORDS,           6
