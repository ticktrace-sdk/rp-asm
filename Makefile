## rp-asm - pure-assembly RP2350 SDK
##   make           build/blinky.uf2
##   make examples  build/<name>.uf2 for every examples/<name>.S
##   make dump      objdump -d of the ELF
##   make clean
##
## Test targets (see tests/README.md for the full strategy):
##   make test          T1 + T2 (Unicorn + QEMU)
##   make test-t1       Unicorn host harness
##   make test-t2       QEMU semihosting sanity / ISA cases
##   make test-t3       Renode integration (skips if not installed)
##   make test-all      everything (T1 + T2 + T3)

ASM      := arm-none-eabi-as
LD       := arm-none-eabi-ld
OBJCOPY  := arm-none-eabi-objcopy
OBJDUMP  := arm-none-eabi-objdump
SIZE     := arm-none-eabi-size

ASFLAGS  := -mcpu=cortex-m33 -mthumb -mimplicit-it=always -I include --warn
LDFLAGS  := -T link/sram.ld -nostdlib --gc-sections

# Driver / startup objects shared by every image.  src/main.S supplies the
# default `main` symbol for build/blinky.elf; examples replace it via
# DRIVER_SRC + the example's own .S.
DRIVER_SRC := \
    src/startup.S \
    src/uart.S    \
    src/gpio.S    \
    src/xosc.S    \
    src/pll.S     \
    src/clocks.S  \
    src/watchdog.S \
    src/powman.S  \
    src/tick.S
# --- M3-C (DMA) additive append - keep on its own line so orchestrator can
#     merge sibling milestone agents (timer, gpio/pads, pwm) without conflict.
DRIVER_SRC += src/dma.S
# --- M4-F (I2C) additive append - DesignWare DW_apb_i2c, both instances.
DRIVER_SRC += src/i2c.S
# --- M4-G (SPI) additive append - PL022, both instances.
DRIVER_SRC += src/spi.S
# --- M4-H (USB) additive append - device controller + CDC-ACM.
DRIVER_SRC += src/usb.S
# --- M5-L (SHA256) additive append - hardware SHA-256 accelerator.
DRIVER_SRC += src/sha256.S
# --- M5-J (ADC, TRNG) additive append.
DRIVER_SRC += src/adc.S
DRIVER_SRC += src/trng.S
# --- M5-I (PIO) additive append - controller side.  pioasm deferred.
DRIVER_SRC += src/pio.S
# --- Trace (CoreSight DWT/ITM/TPIU/ETM) for T4 hardware debugging.
DRIVER_SRC += src/trace.S
# --- Scheduler (NVIC-priority kernel, QV-style).
DRIVER_SRC += src/sched.S
# Scheduler depends on nvic.S helpers; sched-using examples must
# `.include "src/nvic.S"` themselves (matches the pattern other examples
# use for timer.S / systick.S etc).

DRIVER_OBJ := $(patsubst src/%.S, build/%.o, $(DRIVER_SRC))

SRC      := $(DRIVER_SRC) src/main.S
OBJ      := $(patsubst src/%.S, build/%.o, $(SRC))

TARGET   := build/blinky
LOAD_ADDR := 0x20000000

# Examples auto-discovered.
EXAMPLE_SRC := $(wildcard examples/*.S)
EXAMPLE_UF2 := $(patsubst examples/%.S, build/%.uf2, $(EXAMPLE_SRC))

# Benchmarks: every benchmarks/rp_asm/bench_*.S becomes build/<name>.uf2.
# bench_lib.S is a shared helper, NOT itself a bench.
BENCH_SRC := $(filter-out benchmarks/rp_asm/bench_lib.S, $(wildcard benchmarks/rp_asm/bench_*.S))
BENCH_UF2 := $(patsubst benchmarks/rp_asm/%.S, build/%.uf2, $(BENCH_SRC))
BENCH_ELF := $(patsubst benchmarks/rp_asm/%.S, build/%.elf, $(BENCH_SRC))

.PHONY: all examples bench bench-sizes dump clean test test-t1 test-t2 test-t3 test-all
.PRECIOUS: build/%.elf build/%.bin
all: $(TARGET).uf2

examples: $(EXAMPLE_UF2)

bench: $(BENCH_UF2)

# -------------------------------------------------------------- main image
$(TARGET).uf2: $(TARGET).bin tools/uf2.py
	@python3 tools/uf2.py $< $(LOAD_ADDR) $@
	@echo "  UF2     $@"

$(TARGET).bin: $(TARGET).elf
	@$(OBJCOPY) -O binary $< $@
	@echo "  BIN     $@"

$(TARGET).elf: $(OBJ) link/sram.ld
	@mkdir -p $(@D)
	@$(LD) $(LDFLAGS) -Map=build/blinky.map -o $@ $(OBJ)
	@$(SIZE) $@

# -------------------------------------------------------------- examples
# Each examples/<name>.S supplies its own `main` symbol and is linked
# against every src/* driver EXCEPT src/main.S (avoids symbol collision).
build/%.elf: examples/%.S $(DRIVER_OBJ) link/sram.ld
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o build/$*.example.o $<
	@$(LD) $(LDFLAGS) -Map=build/$*.map -o $@ $(DRIVER_OBJ) build/$*.example.o
	@$(SIZE) $@

build/%.bin: build/%.elf
	@$(OBJCOPY) -O binary $< $@
	@echo "  BIN     $@"

build/%.uf2: build/%.bin tools/uf2.py
	@python3 tools/uf2.py $< $(LOAD_ADDR) $@
	@echo "  UF2     $@"

# -------------------------------------------------------------- benchmarks
# Like examples, but: (a) link in benchmarks/rp_asm/bench_lib.S, (b) bench
# files supply their own `main` (except bench_minimum which has its own
# _reset_bench and skips main.S entirely - handled by it not exporting main).
build/bench_lib.o: benchmarks/rp_asm/bench_lib.S
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o $@ $<
	@echo "  AS      $<"

build/%.elf: benchmarks/rp_asm/%.S $(DRIVER_OBJ) build/bench_lib.o link/sram.ld
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o build/$*.bench.o $<
	@$(LD) $(LDFLAGS) -Map=build/$*.map -o $@ $(DRIVER_OBJ) build/bench_lib.o build/$*.bench.o
	@$(SIZE) $@

# bench-sizes: just emit the .text+.rodata size table without running anything
bench-sizes: $(BENCH_ELF)
	@echo ""
	@echo "==== rp-asm benchmark image sizes ===="
	@printf "  %-32s  %8s  %8s\n" "image" "text" "total"
	@for elf in $(BENCH_ELF); do \
	    sz=$$($(SIZE) -d "$$elf" | awk 'NR==2 {printf "  %8d  %8d", $$1, $$1+$$2}'); \
	    printf "  %-32s%s\n" "$$(basename $$elf)" "$$sz"; \
	done

# -------------------------------------------------------------- objects
build/%.o: src/%.S include/rp2350.inc include/clocks.inc
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o $@ $<
	@echo "  AS      $<"

dump: $(TARGET).elf
	@$(OBJDUMP) -d -S $< | less

clean:
	@rm -rf build

# ---------------------------------------------------------------- Test tiers
# Each tier prints its own PASS/FAIL line; the umbrella targets aggregate
# them and exit non-zero on the first failure (set -e).  We deliberately do
# NOT wrap pytest in `|| true` so a regression breaks the build.

PYTEST ?= python3 -m pytest -q

test-t1: $(TARGET).elf $(EXAMPLE_UF2)
	@echo "==== T1 (Unicorn host harness) ===="
	@$(PYTEST) tests/unicorn
	@echo "PASS: T1"

test-t2:
	@echo "==== T2 (QEMU semihosting smoke) ===="
	@$(PYTEST) tests/qemu
	@echo "PASS: T2"

test-t3: $(TARGET).elf
	@echo "==== T3 (Renode integration) ===="
	@bash tests/renode/run.sh
	@echo "DONE: T3"

test: test-t1 test-t2
	@echo ""
	@echo "==== make test summary ===="
	@echo "  T1 (Unicorn): PASS"
	@echo "  T2 (QEMU):    PASS"

test-all: test-t1 test-t2 test-t3
	@echo ""
	@echo "==== make test-all summary ===="
	@echo "  T1 (Unicorn): PASS"
	@echo "  T2 (QEMU):    PASS"
	@echo "  T3 (Renode):  see above (PASS or SKIP)"
