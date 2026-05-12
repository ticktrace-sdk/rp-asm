@ =============================================================================
@ adc.inc - RP2350 ADC (datasheet §12.4)
@
@ 12-bit SAR ADC. RP2350 exposes 8 external inputs (ADC0..7 = GP40..47) plus
@ an internal temperature sensor on channel 8. clk_adc must be ~48 MHz; M2's
@ clocks_init sets clk_adc = pll_usb = 48 MHz.
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

    @ Channel aliases (RP2350: 8 external + temp sensor on chan 8)
    .equ ADC_CH_GP40,         0
    .equ ADC_CH_GP41,         1
    .equ ADC_CH_GP42,         2
    .equ ADC_CH_GP43,         3
    .equ ADC_CH_GP44,         4
    .equ ADC_CH_GP45,         5
    .equ ADC_CH_GP46,         6
    .equ ADC_CH_GP47,         7
    .equ ADC_CH_TEMP,         8

    .equ DREQ_ADC,            36
