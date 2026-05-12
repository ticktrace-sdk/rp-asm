@ =============================================================================
@ examples/gpio_test_fixture.S - test-only fixture that *references* every
@ public gpio_* / gpio_qspi_* symbol so --gc-sections doesn't drop them.
@
@ Built as build/gpio_test_fixture.elf via the generic examples/*.S rule;
@ tests/unicorn/test_gpio.py loads this ELF and calls each function via
@ AAPCS for direct unit testing.
@
@ The "main" here just spins after touching every entry point; real
@ firmware never runs this image.
@ =============================================================================

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .global  main
    .thumb_func
    .section .text.main, "ax"
main:
    @ Reference table - addresses go into ldr =sym so the linker keeps
    @ each section.  Loading them into r0 is enough; the constant pool
    @ gets emitted right after.
    ldr     r0, =gpio_init
    ldr     r0, =gpio_deinit
    ldr     r0, =gpio_set_function
    ldr     r0, =gpio_set_dir
    ldr     r0, =gpio_put
    ldr     r0, =gpio_get
    ldr     r0, =gpio_toggle
    ldr     r0, =gpio_pull_up
    ldr     r0, =gpio_pull_down
    ldr     r0, =gpio_disable_pulls
    ldr     r0, =gpio_set_input_enabled
    ldr     r0, =gpio_set_drive_strength
    ldr     r0, =gpio_set_slew_fast
    ldr     r0, =gpio_set_schmitt
    ldr     r0, =gpio_set_irq_enabled
    ldr     r0, =gpio_acknowledge_irq
    ldr     r0, =gpio_qspi_set_function
    ldr     r0, =gpio_qspi_set_irq_enabled
    ldr     r0, =gpio_qspi_acknowledge_irq
    ldr     r0, =gpio_led_init
    ldr     r0, =gpio_led_toggle
1:  b       1b
