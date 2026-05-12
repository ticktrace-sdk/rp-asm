@ =============================================================================
@ examples/gpio_irq_demo.S - GPIO0 EDGE_LOW IRQ -> toggles on-board LED.
@
@ Demonstrates the gpio_set_irq_enabled / gpio_acknowledge_irq plumbing.
@
@ NOTE on the polling loop:
@   M3-A's scope is GPIO + PADS only - we deliberately do NOT touch
@   src/startup.S (which owns the vector table) or wire up the NVIC.
@   The other M3 agents (TIMER+SysTick, DMA, PWM) will add NVIC vectoring
@   in their slot.  Until then, this demo polls PROC0_INTS which carries
@   the SAME masked-and-enabled bit that would have driven the NVIC line:
@   the test we care about is "gpio_set_irq_enabled enables the right
@   nibble; gpio_acknowledge_irq clears it".
@
@ Boot path:
@   1. clocks_init etc
@   2. gpio_init(0) + pull-up + IE on the pad (so we can sense the line)
@   3. gpio_init(25) + set as output (LED)
@   4. gpio_set_irq_enabled(0, EDGE_LOW, 1)
@   5. forever: poll INTS.GPIO0 nibble for EDGE_LOW; on hit -> toggle LED25
@
@ Trigger by tying GP0 to GND through a momentary switch.
@
@ Build:    make examples/gpio_irq_demo.uf2
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .equ IRQ_PIN, 0
    .equ LED_PIN, 25

    .equ GPIO_IRQ_EDGE_LOW, 4

    .equ IO_BANK0_BASE,         0x40028000
    .equ IO_BANK0_PROC0_INTS0,  0x278

    .section .text.main, "ax"
    .thumb_func
    .global  main
main:
    @ ---- Clock tree bring-up --------------------------------------------
    bl      xosc_init
    bl      pll_sys_150_mhz
    bl      pll_usb_48_mhz
    bl      clocks_init
    bl      tick_init
    bl      watchdog_disable

    @ ---- LED on GP25 as output ------------------------------------------
    movs    r0, #LED_PIN
    bl      gpio_init
    movs    r0, #LED_PIN
    movs    r1, #1
    bl      gpio_set_dir

    @ ---- GP0 as input with pull-up + IE ---------------------------------
    movs    r0, #IRQ_PIN
    bl      gpio_init
    movs    r0, #IRQ_PIN
    bl      gpio_pull_up
    movs    r0, #IRQ_PIN
    movs    r1, #1
    bl      gpio_set_input_enabled

    @ ---- Enable EDGE_LOW IRQ on GP0 -------------------------------------
    movs    r0, #IRQ_PIN
    movs    r1, #GPIO_IRQ_EDGE_LOW
    movs    r2, #1
    bl      gpio_set_irq_enabled

    @ ---- Polling "ISR" --------------------------------------------------
    @ INTS array: nibble (pin%8)*4 in word [pin/8].  GP0 lives at bits 2:3
    @ of INTS0 (offset 0x278).  EDGE_LOW = 1<<2 in the nibble.
    ldr     r4, =IO_BANK0_BASE + IO_BANK0_PROC0_INTS0
    movs    r5, #GPIO_IRQ_EDGE_LOW          @ mask = 0b0100 in nibble 0
.Lloop:
    ldr     r0, [r4]
    ands    r0, r5
    beq     .Lloop                          @ wait for the edge

    @ Service: toggle LED, then ack the event.
    movs    r0, #LED_PIN
    bl      gpio_toggle

    movs    r0, #IRQ_PIN
    movs    r1, #GPIO_IRQ_EDGE_LOW
    bl      gpio_acknowledge_irq

    b       .Lloop
