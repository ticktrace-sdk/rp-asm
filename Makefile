## rp-asm - pure-assembly RP2350 SDK
##   make           build/blinky.uf2
##   make examples  build/<name>.uf2 for every examples/<name>.S
##   make dump      objdump -d of the ELF
##   make clean
##
## Test targets (see tests/README.md for the full strategy):
##   make pydeps        create .venv and install Python deps for T1/T2
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
# --- SPSC byte queue (lock-free ISR -> task data path).
DRIVER_SRC += src/spsc.S
# --- Per-task DWT cycle accounting (opt-in via task_create_traced).
DRIVER_SRC += src/sched_stats.S
# --- M7 (QMI) additive append - flash speed tuning.
DRIVER_SRC += src/qmi.S
# --- M7 (OTP) additive append - read-only access to factory + user rows.
DRIVER_SRC += src/otp.S
# --- M7 (bootrom services) additive append.  bootrom.S provides
# rom_reset_to_bootsel, which the USB CDC stack also invokes on the
# 1200-baud reboot trick.  BOOTRAM itself is bootrom-owned per RP2350
# datasheet sec 4.3 - we expose only the register-block constants in
# include/bootram.inc; no driver.
DRIVER_SRC += src/bootrom.S
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

.PHONY: all examples bench bench-sizes dump clean test test-t1 test-t2 test-t3 test-tools test-all pydeps tools
.PRECIOUS: build/%.elf build/%.bin build/%_flash.elf build/%_flash.bin \
           build/%_signed_flash.bin build/%_encrypted_flash.elf
all: $(TARGET).uf2

# ============================================================================
# Go tools — `rpasm` static binary, replacement for the Python helpers.
# Phase 1a (this commit) ships `rpasm uf2 pack` at byte-parity with
# tools/uf2.py. Phase 1b adds mkmanifest, mkfirmware. Phase 3 adds dfu.
# ============================================================================
GO     ?= go
RPASM  := tools/bin/rpasm
GO_SRC := $(shell find tools -name '*.go' -not -path 'tools/bin/*' 2>/dev/null)

$(RPASM): $(GO_SRC) tools/go.mod
	@cd tools && $(GO) build -o bin/rpasm ./cmd/rpasm
	@echo "  GO      $@"

tools: $(RPASM)

# The Python uf2.py is still the default packer until Phase 1b. The Go tool
# is built alongside it and exercised by tests/tools/test_uf2_parity.py so
# any divergence is caught before we flip the Makefile rules over.

examples: $(EXAMPLE_UF2)

bench: $(BENCH_UF2)

# ============================================================================
# C bridge — opt-in: builds C apps that link against the asm core.
# Default `make` does NOT pull these in; users opt-in with `make c-apps`.
# ============================================================================
CC      := arm-none-eabi-gcc

CFLAGS  := -mcpu=cortex-m33 -mthumb -mfloat-abi=soft \
           -ffreestanding -fno-builtin -nostdlib \
           -ffunction-sections -fdata-sections \
           -Wall -Wextra -O2 \
           -I c_bridge/include

C_BRIDGE_SRC := c_bridge/runtime.S c_bridge/asm_libc.S
C_BRIDGE_OBJ := $(patsubst c_bridge/%.S, build/c_bridge/%.o, $(C_BRIDGE_SRC))

C_APP_DIRS := $(wildcard c_apps/*)
C_APP_UF2  := $(patsubst c_apps/%, build/%.uf2, $(C_APP_DIRS))

.PHONY: c-apps
c-apps: $(C_APP_UF2)

# Each c_apps/<name>/*.c becomes build/<name>.elf linked with DRIVER_OBJ +
# C_BRIDGE_OBJ.
build/c_bridge/%.o: c_bridge/%.S
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o $@ $<
	@echo "  AS      $<"

# Pattern: build/<name>.elf  <- c_apps/<name>/*.c
build/%.elf: c_apps/%/main.c $(DRIVER_OBJ) $(C_BRIDGE_OBJ) link/sram.ld
	@mkdir -p $(@D)
	@$(CC) $(CFLAGS) -c $< -o build/$*.c.o
	@$(LD) $(LDFLAGS) -Map=build/$*.map -o $@ \
	    $(DRIVER_OBJ) $(C_BRIDGE_OBJ) build/$*.c.o
	@$(SIZE) $@

# ============================================================================
# Rust bridge — also opt-in.  Builds librp_asm.a (static archive of all
# DRIVER_OBJ), then cargo links against it from rust_apps/*.
# ============================================================================
AR := arm-none-eabi-ar

build/librp_asm.a: $(DRIVER_OBJ) $(C_BRIDGE_OBJ)
	@mkdir -p $(@D)
	@rm -f $@
	@$(AR) rcs $@ $(DRIVER_OBJ) $(C_BRIDGE_OBJ)
	@echo "  AR      $@"

RUST_APP_DIRS := $(wildcard rust_apps/*)
RUST_APP_UF2  := $(patsubst rust_apps/%, build/%.uf2, $(RUST_APP_DIRS))

.PHONY: rust-apps
rust-apps: $(RUST_APP_UF2)

# Each rust_apps/<name>/ is a cargo project.  Build, locate the ELF,
# objcopy to .bin, UF2-pack.
build/%.elf: rust_apps/%/Cargo.toml build/librp_asm.a
	@mkdir -p $(@D)
	@cd rust_apps/$* && cargo build --release --quiet
	@cp rust_apps/$*/target/thumbv8m.main-none-eabi/release/$* $@
	@$(SIZE) $@

# -------------------------------------------------------------- flash bridges
# Same C / Rust apps but linked at 0x10000000 for real-hardware boot.
# Uses link/flash.ld; otherwise identical to the SRAM rules above.
build/%_flash.elf: c_apps/%/main.c $(DRIVER_OBJ) $(C_BRIDGE_OBJ) link/flash.ld
	@mkdir -p $(@D)
	@$(CC) $(CFLAGS) -c $< -o build/$*.c.o
	@$(LD) -T link/flash.ld -nostdlib --gc-sections -Map=build/$*_flash.map -o $@ \
	    $(DRIVER_OBJ) $(C_BRIDGE_OBJ) build/$*.c.o
	@$(SIZE) $@

build/%_flash.elf: rust_apps/%/Cargo.toml build/librp_asm.a
	@mkdir -p $(@D)
	@cd rust_apps/$* && RP_ASM_LINK_SCRIPT=$(abspath link/flash.ld) \
	    CARGO_TARGET_DIR=target_flash cargo build --release --quiet
	@cp rust_apps/$*/target_flash/thumbv8m.main-none-eabi/release/$* $@
	@$(SIZE) $@

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

# ============================================================================
# Bootloader chain — SSBL + TSBL-bypass + app slot A.
#
# Three stages, three binaries, each sealed with a 256-byte footer (CRC32 +
# SHA-256) produced by `rpasm mkmanifest`. `rpasm mkfirmware` then stitches
# them into a single one-drag-drop UF2.
#
# Stage diagram (Phase 1, single-slot -bypass flavor):
#   0x10000000  SSBL          (4 KiB; no footer in Phase 1)
#   0x10001000  TSBL-bypass   (≤ 24 KiB - 256)
#   0x10006F00  TSBL footer   (256 B; produced by mkmanifest from tsbl bin)
#   0x10008000  app           (≤ 480 KiB - 256)
#   0x1007FF00  app footer    (256 B)
# ============================================================================

# crc32.o is shared between the SSBL and TSBL builds. Each ELF includes its
# own copy (no service-table dependency between stages).
build/crc32.o: src/crc32.S
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o $@ $<
	@echo "  AS      $<"

# --- SSBL --------------------------------------------------------------------
build/ssbl/%.o: src/ssbl/%.S include/rp2350.inc include/bootloader.inc
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o $@ $<
	@echo "  AS      $<"

build/ssbl.elf: build/ssbl/ssbl.o build/crc32.o link/ssbl.ld
	@$(LD) -T link/ssbl.ld -nostdlib --gc-sections -Map=build/ssbl.map -o $@ \
	    build/ssbl/ssbl.o build/crc32.o
	@$(SIZE) $@

# --- TSBL flavors ------------------------------------------------------------
build/tsbl/%.o: src/tsbl/%.S include/rp2350.inc include/bootloader.inc
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o $@ $<
	@echo "  AS      $<"

build/tsbl_bypass.elf: build/tsbl/tsbl_bypass.o build/crc32.o link/tsbl.ld
	@$(LD) -T link/tsbl.ld -nostdlib --gc-sections -Map=build/tsbl_bypass.map -o $@ \
	    build/tsbl/tsbl_bypass.o build/crc32.o
	@$(SIZE) $@

# --- Apps linked at the bootloader's slot-A base ----------------------------
# Mirrors the existing `_flash.elf` pattern but targets 0x10008000. Use this
# when an example is destined for the bootloader chain rather than the bare
# bootrom path.
build/%_app.elf: examples/%.S $(DRIVER_OBJ) link/app_at_0x10008000.ld
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o build/$*.example.o $<
	@$(LD) -T link/app_at_0x10008000.ld -nostdlib --gc-sections \
	    -Map=build/$*_app.map -o $@ $(DRIVER_OBJ) build/$*.example.o
	@$(SIZE) $@

# --- Footers (CRC32 + SHA-256 manifest) -------------------------------------
# Status defaults to "good" in Phase 1 since there's no A/B selection logic
# yet to interpret STAGED/TRYING/GOOD. Phase 2 will start writing other
# statuses via the host DFU tool, not at build time.
build/%.footer.bin: build/%.bin $(RPASM)
	@$(RPASM) mkmanifest $< -o $@ -status good

# --- Combined firmware UF2 ---------------------------------------------------
# `make build/firmware_blinky.uf2` packs SSBL + TSBL-bypass + their footers
# + blinky as the app + its footer into one drag-droppable image.
build/firmware_%.uf2: \
        build/ssbl.bin \
        build/tsbl_bypass.bin build/tsbl_bypass.footer.bin \
        build/%_app.bin build/%_app.footer.bin \
        $(RPASM)
	@$(RPASM) mkfirmware -o $@ \
	    0x10000000:build/ssbl.bin \
	    0x10001000:build/tsbl_bypass.bin \
	    0x10006F00:build/tsbl_bypass.footer.bin \
	    0x10008000:build/$*_app.bin \
	    0x1007FF00:build/$*_app.footer.bin
	@echo "  UF2     $@"

.PHONY: bootloader
bootloader: build/ssbl.bin build/tsbl_bypass.bin
	@echo "  BL      built SSBL + TSBL-bypass"

# -------------------------------------------------------------- flash variants
# Default `blinky` is built from src/main.S; build/blinky_flash.uf2 produces
# the same image linked at 0x10000000 for hardware boot.
build/blinky_flash.elf: $(OBJ) link/flash.ld
	@mkdir -p $(@D)
	@$(LD) -T link/flash.ld -nostdlib --gc-sections -Map=build/blinky_flash.map -o $@ $(OBJ)
	@$(SIZE) $@

# Same source(s) as the SRAM image, but linked at 0x10000000 (XIP window).
# Use these when targeting real hardware via BOOTSEL UF2 - SRAM-resident
# images currently do not run reliably on the RP2350-A2 silicon shipping in
# Pico 2 boards (the bootrom hands off but the core never reaches main).
FLASH_LOAD_ADDR := 0x10000000

build/%_flash.elf: examples/%.S $(DRIVER_OBJ) link/flash.ld
	@mkdir -p $(@D)
	@$(ASM) $(ASFLAGS) -o build/$*.example.o $<
	@$(LD) -T link/flash.ld -nostdlib --gc-sections -Map=build/$*_flash.map -o $@ $(DRIVER_OBJ) build/$*.example.o
	@$(SIZE) $@

build/%_flash.bin: build/%_flash.elf
	@$(OBJCOPY) -O binary $< $@
	@echo "  BIN     $@"

build/%_flash.uf2: build/%_flash.bin tools/uf2.py
	@python3 tools/uf2.py $< $(FLASH_LOAD_ADDR) $@
	@echo "  UF2     $@"

# -------------------------------------------------------------- secure boot
# M8: signed (M8.1) and encrypted+signed (M8.2) image flows.  Picotool does
# all the crypto - we just wire up the keygen, seal/encrypt invocation, and
# a UF2 pack of the sealed binary.  M8.1 produces a flash-bootable signed
# UF2 on any stock RP2350.  M8.2 produces a correctly built encrypted UF2
# but flashing it requires the AES key in OTP first - see the note above
# the encrypted target below.
#
# Override PICOTOOL on the command line or env if your picotool is elsewhere:
#   make build/blinky_signed_flash.uf2 PICOTOOL=/usr/local/bin/picotool
PICOTOOL ?= $(HOME)/picotool/build/picotool
KEYS_DIR := keys/dev
PRIVATE_PEM := $(KEYS_DIR)/private.pem
AES_KEY := $(KEYS_DIR)/privateaes.bin
IV_SALT := $(KEYS_DIR)/ivsalt.bin

# keygen.sh is idempotent: re-running it leaves existing keys alone.
$(PRIVATE_PEM) $(AES_KEY) $(IV_SALT): tools/keygen.sh
	@./tools/keygen.sh

# ----- Signed only (no encryption) -------------------------------------------
# Pattern: build/<name>_signed_flash.uf2 <- build/<name>_flash.bin + dev key.
# picotool seal needs the load offset for a BIN input and an OTP scratch
# JSON; we steer it into build/ so a `make clean` removes it.
build/%_signed_flash.bin: build/%_flash.bin $(PRIVATE_PEM)
	@$(PICOTOOL) seal --quiet --hash --sign \
	    $< -t bin -o $(FLASH_LOAD_ADDR) \
	    $@ -t bin \
	    $(PRIVATE_PEM) build/$*_signed_otp.json
	@echo "  SEAL    $@"

build/%_signed_flash.uf2: build/%_signed_flash.bin tools/uf2.py
	@python3 tools/uf2.py $< $(FLASH_LOAD_ADDR) $@
	@echo "  UF2     $@"

# ----- Encrypted + signed ----------------------------------------------------
# picotool encrypt --embed includes a small decryptor bootloader stub in the
# output ELF and re-targets it for SRAM (0x20000000) - the stub runs from
# SRAM, decrypts the payload, verifies the signature, then jumps.  Because
# the ELF is no longer a plain XIP image we let picotool produce the UF2
# directly (its own `uf2 convert` knows the layout); our tools/uf2.py
# assumes a single contiguous load region and would not handle the layout.
#
# NOT FLASHABLE ON A STOCK CHIP.  The embedded decryptor stub (picotool's
# enc_bootloader/enc_bootloader.c) reads the AES key from OTP unconditionally
# (key shares at pages 29 & 30, IV salt at page 31).  Blank OTP -> guarded
# read faults -> rom_chain_image rejects the image -> chip drops back to
# BOOTSEL.  There is no flash-resident-key dev mode in the bootrom-chain
# decryptor.  To actually run an encrypted image you must `picotool otp load
# build/<name>_encrypted_otp.json` first - that burn is per-chip and partly
# irreversible (PAGE2{9,30,31}_LOCK1 = 0x3d3d3d).  The build path here is
# kept so the keygen + picotool plumbing is exercised and the OTP json is
# produced for a future provisioning step; flash the M8.1 signed UF2 for
# hardware tests in the meantime.
build/%_encrypted_flash.elf: build/%_flash.elf $(PRIVATE_PEM) $(AES_KEY) $(IV_SALT)
	@$(PICOTOOL) encrypt --quiet --embed --hash --sign \
	    $< -t elf \
	    $@ -t elf \
	    $(AES_KEY) $(IV_SALT) $(PRIVATE_PEM) build/$*_encrypted_otp.json
	@echo "  ENC     $@"

build/%_encrypted_flash.uf2: build/%_encrypted_flash.elf
	@$(PICOTOOL) uf2 convert --quiet $< -t elf $@ -t uf2 --family rp2350-arm-s
	@echo "  UF2     $@"

.PHONY: keys
keys: $(PRIVATE_PEM) $(AES_KEY) $(IV_SALT)


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

# Prefer .venv if it exists so `make test-*` picks up deps installed via
# `make pydeps`; otherwise fall back to the system python3.
VENV         := .venv
VENV_PY      := $(VENV)/bin/python
PY           := $(if $(wildcard $(VENV_PY)),$(VENV_PY),python3)
PYTEST       ?= $(PY) -m pytest -q

# pydeps: create .venv (if missing) and install Python test deps.
pydeps: $(VENV_PY)
	@echo "==== installing Python test deps into $(VENV) ===="
	@$(VENV_PY) -m pip install --quiet --upgrade pip
	@$(VENV_PY) -m pip install --quiet -r tests/unicorn/requirements.txt
	@echo "PASS: pydeps  ($$($(VENV_PY) -c "import unicorn; print('unicorn', unicorn.__version__)"))"

$(VENV_PY):
	@echo "==== creating venv at $(VENV) ===="
	@python3 -m venv $(VENV)

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

test-tools: $(RPASM)
	@echo "==== Go tools: unit tests ===="
	@cd tools && $(GO) test ./...
	@echo "==== Go tools: uf2 parity vs tools/uf2.py ===="
	@$(PYTEST) tests/tools
	@echo "PASS: test-tools"

test: test-t1 test-t2 test-tools
	@echo ""
	@echo "==== make test summary ===="
	@echo "  T1 (Unicorn): PASS"
	@echo "  T2 (QEMU):    PASS"
	@echo "  tools:        PASS"

test-all: test-t1 test-t2 test-t3 test-tools
	@echo ""
	@echo "==== make test-all summary ===="
	@echo "  T1 (Unicorn): PASS"
	@echo "  T2 (QEMU):    PASS"
	@echo "  T3 (Renode):  see above (PASS or SKIP)"
	@echo "  tools:        PASS"
