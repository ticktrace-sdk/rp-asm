## rp-asm - pure-assembly RP2350 SDK
##   make           build/blinky.uf2
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
LDFLAGS  := -T link/sram.ld -nostdlib --gc-sections -Map=build/blinky.map

SRC      := src/startup.S src/main.S src/uart.S src/gpio.S
OBJ      := $(patsubst src/%.S, build/%.o, $(SRC))

TARGET   := build/blinky
LOAD_ADDR := 0x20000000

.PHONY: all dump clean test test-t1 test-t2 test-t3 test-all
all: $(TARGET).uf2

$(TARGET).uf2: $(TARGET).bin tools/uf2.py
	@python3 tools/uf2.py $< $(LOAD_ADDR) $@
	@echo "  UF2     $@"

$(TARGET).bin: $(TARGET).elf
	@$(OBJCOPY) -O binary $< $@
	@echo "  BIN     $@"

$(TARGET).elf: $(OBJ) link/sram.ld
	@mkdir -p $(@D)
	@$(LD) $(LDFLAGS) -o $@ $(OBJ)
	@$(SIZE) $@

build/%.o: src/%.S include/rp2350.inc
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

test-t1: $(TARGET).elf
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
