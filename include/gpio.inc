@ =============================================================================
@ gpio.inc - RP2350 IO_BANK0 + IO_QSPI register map and bit definitions.
@
@ Cross-checked against RP2350 datasheet rev 0.3 (Aug 2024) sec 9.1 (IO_BANK0)
@ and sec 9.2 (IO_QSPI).
@
@ This file is `.include`-d alongside rp2350.inc; it intentionally avoids
@ redefining symbols already in rp2350.inc (IO_BANK0_BASE, GPIO_FUNC_SIO,
@ GPIO_FUNC_UART, IO_BANK0_GPIO_CTRL_STRIDE, ATOMIC_*, SIO_BASE).
@
@ Atomic register aliases on IO_BANK0 / IO_QSPI follow the standard APB
@ pattern (+0x1000 XOR / +0x2000 SET / +0x3000 CLR).
@ =============================================================================
@
@ ---- Per-GPIO layout (datasheet sec 9.1.4) ----------------------------------
@   Each user GPIO has an 8-byte block: { STATUS, CTRL }.
@     IO_BANK0_GPIO[n]_STATUS  = IO_BANK0_BASE + 0 + n * 8
@     IO_BANK0_GPIO[n]_CTRL    = IO_BANK0_BASE + 4 + n * 8
@   IO_BANK0_GPIO_CTRL_STRIDE (8) and the OFFS_CTRL constant (4) come from
@   rp2350.inc.  We add a STATUS offset for completeness.
    .equ IO_BANK0_GPIO_STATUS_OFFS,  0
    .equ IO_BANK0_GPIO_CTRL_OFFS,    4
    .equ IO_BANK0_NUM_GPIOS,         48     @ RP2350: 48 user GPIOs

@ CTRL register fields (datasheet sec 9.1.4):
@   [4:0]   FUNCSEL
@   [13:12] OUTOVER  (0=peripheral, 1=invert, 2=low, 3=high)
@   [17:16] OEOVER   (0=peripheral, 1=invert, 2=disable, 3=enable)
@   [19:18] INOVER   (0=peripheral, 1=invert, 2=low, 3=high)
@   [29:28] IRQOVER  (0=int, 1=invert, 2=low, 3=high)
    .equ GPIO_CTRL_FUNCSEL_LSB,      0
    .equ GPIO_CTRL_FUNCSEL_MASK,     0x1F
    .equ GPIO_CTRL_OUTOVER_LSB,      12
    .equ GPIO_CTRL_OEOVER_LSB,       16
    .equ GPIO_CTRL_INOVER_LSB,       18
    .equ GPIO_CTRL_IRQOVER_LSB,      28

@ ---- Function selects (datasheet sec 9.1.1, table 597) ----------------------
@   GPIO_FUNC_SIO and _UART are already defined in rp2350.inc.  Listed here
@   as guarded definitions so this file can also be included stand-alone.
    .ifndef GPIO_FUNC_SIO
        .equ GPIO_FUNC_SIO,   5
    .endif
    .ifndef GPIO_FUNC_UART
        .equ GPIO_FUNC_UART,  2
    .endif
    .equ GPIO_FUNC_XIP,       0
    .equ GPIO_FUNC_SPI,       1
    .equ GPIO_FUNC_I2C,       3
    .equ GPIO_FUNC_PWM,       4
    .equ GPIO_FUNC_PIO0,      6
    .equ GPIO_FUNC_PIO1,      7
    .equ GPIO_FUNC_PIO2,      8
    .equ GPIO_FUNC_GPCK,      9     @ HSTX / clock GPIO function on RP2350
    .equ GPIO_FUNC_USB,       10
    .equ GPIO_FUNC_UART_AUX,  11
    .equ GPIO_FUNC_NULL,      31

@ ---- IRQ event encoding (datasheet sec 9.1.4 INTE/INTF/INTS/INTR) -----------
@   Per pin, a 4-bit nibble at bit position (n%8)*4 in the [n/8]-th register.
@     bit 0  LEVEL_LOW
@     bit 1  LEVEL_HIGH
@     bit 2  EDGE_LOW
@     bit 3  EDGE_HIGH
    .equ GPIO_IRQ_LEVEL_LOW,  (1 << 0)
    .equ GPIO_IRQ_LEVEL_HIGH, (1 << 1)
    .equ GPIO_IRQ_EDGE_LOW,   (1 << 2)
    .equ GPIO_IRQ_EDGE_HIGH,  (1 << 3)
    .equ GPIO_IRQ_EDGE_ANY,   (GPIO_IRQ_EDGE_LOW | GPIO_IRQ_EDGE_HIGH)
    .equ GPIO_IRQ_LEVEL_ANY,  (GPIO_IRQ_LEVEL_LOW | GPIO_IRQ_LEVEL_HIGH)

@ ---- IO_BANK0 IRQ register array offsets (datasheet sec 9.1.4) -------------
@   PROC0/PROC1/DORMANT all have a 6-register array (IO_BANK0 has 48 GPIO,
@   so ceil(48/8) = 6 nibble-packed registers).  Each subarray is laid out:
@     INTR     (RAW status, 6 regs)
@     PROC0_INTE / INTF / INTS                                (3 x 6 regs)
@     PROC1_INTE / INTF / INTS                                (3 x 6 regs)
@     DORMANT_WAKE_INTE / INTF / INTS                         (3 x 6 regs)
@   Verified offsets from the datasheet:
@     IRQSUMMARY_PROC0_SECURE0  = 0x100  (and friends, not used here)
@     INTR0                     = 0x230
@     PROC0_INTE0               = 0x248
@     PROC0_INTF0               = 0x260
@     PROC0_INTS0               = 0x278
@     PROC1_INTE0               = 0x290
@     PROC1_INTF0               = 0x2A8
@     PROC1_INTS0               = 0x2C0
@     DORMANT_WAKE_INTE0        = 0x2D8
@     DORMANT_WAKE_INTF0        = 0x2F0
@     DORMANT_WAKE_INTS0        = 0x308
    .equ IO_BANK0_INTR0,                  0x230
    .equ IO_BANK0_PROC0_INTE0,            0x248
    .equ IO_BANK0_PROC0_INTF0,            0x260
    .equ IO_BANK0_PROC0_INTS0,            0x278
    .equ IO_BANK0_PROC1_INTE0,            0x290
    .equ IO_BANK0_PROC1_INTF0,            0x2A8
    .equ IO_BANK0_PROC1_INTS0,            0x2C0
    .equ IO_BANK0_DORMANT_WAKE_INTE0,     0x2D8
    .equ IO_BANK0_DORMANT_WAKE_INTF0,     0x2F0
    .equ IO_BANK0_DORMANT_WAKE_INTS0,     0x308

@ ---- IO_QSPI (datasheet sec 9.2) -------------------------------------------
@   Six pads in this order (datasheet table 654):
@     0  QSPI_SCLK
@     1  QSPI_SS
@     2  QSPI_SD0
@     3  QSPI_SD1
@     4  QSPI_SD2
@     5  QSPI_SD3
@   Per-pin block layout matches IO_BANK0: { STATUS, CTRL } at +0/+4, stride 8.
@   IRQ register array is 1 register wide (only 6 pins) at the same relative
@   offsets as IO_BANK0, but only PROC0/PROC1 plus DORMANT_WAKE are present.
    .equ IO_QSPI_BASE,                 0x40030000
    .equ IO_QSPI_NUM_PINS,             6
    .equ IO_QSPI_PIN_STRIDE,           8
    .equ IO_QSPI_QSPI_SCLK,            0
    .equ IO_QSPI_QSPI_SS,              1
    .equ IO_QSPI_QSPI_SD0,             2
    .equ IO_QSPI_QSPI_SD1,             3
    .equ IO_QSPI_QSPI_SD2,             4
    .equ IO_QSPI_QSPI_SD3,             5

    @ IO_QSPI IRQ array offsets (single 32-bit register per array, since
    @ 6 pins * 4 bits = 24 bits all fit in one word).
    .equ IO_QSPI_INTR,                 0x30
    .equ IO_QSPI_PROC0_INTE,           0x38
    .equ IO_QSPI_PROC0_INTF,           0x40
    .equ IO_QSPI_PROC0_INTS,           0x48
    .equ IO_QSPI_PROC1_INTE,           0x50
    .equ IO_QSPI_PROC1_INTF,           0x58
    .equ IO_QSPI_PROC1_INTS,           0x60
    .equ IO_QSPI_DORMANT_WAKE_INTE,    0x68
    .equ IO_QSPI_DORMANT_WAKE_INTF,    0x70
    .equ IO_QSPI_DORMANT_WAKE_INTS,    0x78

@ ---- SIO upper-half registers for GPIO 32..47 (datasheet sec 3.1.4) --------
@   For pins >= 32 the SIO splits into _HI variants.  Bit position is
@   (pin - 32) within the _HI registers.
    .equ SIO_GPIO_HI_OUT,              0x050
    .equ SIO_GPIO_HI_OUT_SET,          0x058
    .equ SIO_GPIO_HI_OUT_CLR,          0x060
    .equ SIO_GPIO_HI_OUT_XOR,          0x068
    .equ SIO_GPIO_HI_OE,               0x070
    .equ SIO_GPIO_HI_OE_SET,           0x078
    .equ SIO_GPIO_HI_OE_CLR,           0x080
    .equ SIO_GPIO_HI_OE_XOR,           0x088
    .equ SIO_GPIO_IN,                  0x004
    .equ SIO_GPIO_HI_IN,               0x008
