@ =============================================================================
@ timer.inc - RP2350 TIMER0 / TIMER1 (M3-B core peripherals)
@
@ The RP2350 has TWO timer blocks (RP2040 had one).  Each is a 64-bit
@ microsecond counter with four 32-bit-compare alarms.  The 1 MHz tick is
@ supplied by the TICKS peripheral (TIMER0/TIMER1 sub-tickers, started by
@ M2's tick_init).
@
@ Datasheet ref: RP2350 sec 12.8 (TIMER) and sec 8.5 (TICKS).
@
@ Atomic register aliases work the same as other APB peripherals:
@   +0x0000  RW
@   +0x1000  XOR on write
@   +0x2000  SET on write
@   +0x3000  CLR on write
@
@ -----------------------------------------------------------------------------
@ Register map (per timer block, both have identical layout):
@   0x00  TIMEHW    write the high  half of the (write-only) latch
@   0x04  TIMELW    write the low   half - committing both halves to TIME
@   0x08  TIMEHR    read  the high  half of the read latch (latched by TIMELR)
@   0x0c  TIMELR    read  the low   half AND latch the high half
@   0x10  ALARM0    32-bit compare value for alarm 0 (compares against TIMELR)
@   0x14  ALARM1    same for alarm 1
@   0x18  ALARM2    same for alarm 2
@   0x1c  ALARM3    same for alarm 3
@   0x20  ARMED     RW1C of armed flags; alarm n auto-arms when ALARMn written
@   0x24  TIMERAWH  unsynchronised hi half (no latch protocol; for diagnostics)
@   0x28  TIMERAWL  unsynchronised lo half (use this for 32-bit reads)
@   0x2c  DBGPAUSE  pause counter while debugger halted (per-core bits)
@   0x30  PAUSE     halt the counter
@   0x34  INTR      raw interrupt flags (4 bits, one per alarm; W1C)
@   0x38  INTE      interrupt enable
@   0x3c  INTF      interrupt force (test bit)
@   0x40  INTS      interrupt status (INTR & INTE)
@
@ NVIC IRQ lines (datasheet sec 3.2):
@   TIMER0_IRQ_0..3 = 0..3
@   TIMER1_IRQ_0..3 = 4..7
@ =============================================================================

    .equ TIMER0_BASE,           0x400b0000
    .equ TIMER1_BASE,           0x400b8000

    .equ TIMER_TIMEHW,          0x00
    .equ TIMER_TIMELW,          0x04
    .equ TIMER_TIMEHR,          0x08
    .equ TIMER_TIMELR,          0x0c
    .equ TIMER_ALARM0,          0x10
    .equ TIMER_ALARM1,          0x14
    .equ TIMER_ALARM2,          0x18
    .equ TIMER_ALARM3,          0x1c
    .equ TIMER_ARMED,           0x20
    .equ TIMER_TIMERAWH,        0x24
    .equ TIMER_TIMERAWL,        0x28
    .equ TIMER_DBGPAUSE,        0x2c
    .equ TIMER_PAUSE,           0x30
    .equ TIMER_LOCKED,          0x34
    .equ TIMER_SOURCE,          0x38
    .equ TIMER_INTR,            0x3c
    .equ TIMER_INTE,            0x40
    .equ TIMER_INTF,            0x44
    .equ TIMER_INTS,            0x48

    @ Convenience: stride between ALARM registers (4 bytes).
    .equ TIMER_ALARM_STRIDE,    4

    @ RESETS bit positions (datasheet sec 7.5).
    .equ RESETS_timer0,         23
    .equ RESETS_timer1,         24

    @ NVIC line numbers (datasheet sec 3.2 IRQ table).
    @ Each timer exposes one IRQ per alarm.
    .equ IRQ_TIMER0_0,          0
    .equ IRQ_TIMER0_1,          1
    .equ IRQ_TIMER0_2,          2
    .equ IRQ_TIMER0_3,          3
    .equ IRQ_TIMER1_0,          4
    .equ IRQ_TIMER1_1,          5
    .equ IRQ_TIMER1_2,          6
    .equ IRQ_TIMER1_3,          7
