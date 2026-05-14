@ =============================================================================
@ adc.inc - RP2350 ADC (datasheet §12.4)
@
@ 12-bit SAR ADC. clk_adc must be ~48 MHz; M2's clocks_init sets clk_adc =
@ pll_usb = 48 MHz.
@
@ Input channel mapping is package-dependent (datasheet §12.4):
@   RP2350A (QFN-60, Pico 2):
@     0..3 = GP26..29
@     4    = internal temperature sensor
@     5..7 = reserved
@   RP2350B (QFN-80):
@     0..7 = GP40..47
@     8    = internal temperature sensor
@
@ Use ADC_CH_TEMP below rather than hard-coding 4 or 8 in demos.
@ =============================================================================

    .equ ADC_BASE,        0x400a0000
    .equ RESETS_adc,      0

    @ Registers
    .equ ADC_CS,          0x00
    .equ ADC_RESULT,      0x04
    .equ ADC_FCS,         0x08
    .equ ADC_FIFO,        0x0C
    .equ ADC_DIV,         0x10
    .equ ADC_INTR,        0x14
    .equ ADC_INTE,        0x18
    .equ ADC_INTF,        0x1C
    .equ ADC_INTS,        0x20

    @ CS bits
    .equ ADC_CS_EN,           (1 << 0)
    .equ ADC_CS_TS_EN,        (1 << 1)
    .equ ADC_CS_START_ONCE,   (1 << 2)
    .equ ADC_CS_START_MANY,   (1 << 3)
    .equ ADC_CS_READY,        (1 << 8)
    .equ ADC_CS_ERR,          (1 << 9)
    .equ ADC_CS_AINSEL_SHIFT, 12
    .equ ADC_CS_RROBIN_SHIFT, 16

    @ FCS bits
    .equ ADC_FCS_EN,          (1 << 0)
    .equ ADC_FCS_SHIFT,       (1 << 1)
    .equ ADC_FCS_ERR,         (1 << 2)
    .equ ADC_FCS_DREQ_EN,     (1 << 3)
    .equ ADC_FCS_EMPTY,       (1 << 8)
    .equ ADC_FCS_FULL,        (1 << 9)

    @ Channel aliases.  Defaults are for RP2350A (Pico 2, QFN-60):
    @ 4 external inputs on GP26..29 and the temp sensor on chan 4.
    @ On RP2350B (QFN-80) the external inputs span GP40..47 and the
    @ temp sensor is chan 8 - flip the aliases below to match.
    .equ ADC_CH_GP26,         0
    .equ ADC_CH_GP27,         1
    .equ ADC_CH_GP28,         2
    .equ ADC_CH_GP29,         3
    .equ ADC_CH_TEMP,         4

    .equ DREQ_ADC,            36
