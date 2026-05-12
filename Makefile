## rp-asm - pure-assembly RP2350 SDK
##   make           build/blinky.uf2
##   make dump      objdump -d of the ELF
##   make clean

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

.PHONY: all dump clean
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
