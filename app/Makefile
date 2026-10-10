TOOLCHAIN_PREFIX ?= riscv-none-elf-

ifeq ($(wildcard C:/AMDDesignTools/2025.2/gnu/riscv/nt/bin/riscv64-unknown-elf-gcc.exe),C:/AMDDesignTools/2025.2/gnu/riscv/nt/bin/riscv64-unknown-elf-gcc.exe)
    CC = C:/AMDDesignTools/2025.2/gnu/riscv/nt/bin/riscv64-unknown-elf-gcc.exe
    OBJCOPY = C:/AMDDesignTools/2025.2/gnu/riscv/nt/bin/riscv64-unknown-elf-objcopy.exe
else
    CC = $(TOOLCHAIN_PREFIX)gcc
    OBJCOPY = $(TOOLCHAIN_PREFIX)objcopy
endif

CFLAGS  = -march=rv32i -mabi=ilp32 -mno-relax -Os -ffreestanding -Wall
LDFLAGS = -T sections.ld -nostdlib -Wl,--no-relax -Wl,--build-id=none

all: dna_decimal_app.bin dna_decimal_app.hex

dna_decimal_app.elf: start.s main.c sections.ld
	"$(CC)" $(CFLAGS) $(LDFLAGS) -o dna_decimal_app.elf start.s main.c

dna_decimal_app.bin: dna_decimal_app.elf
	"$(OBJCOPY)" -O binary dna_decimal_app.elf dna_decimal_app.bin

dna_decimal_app.hex: dna_decimal_app.bin
	python generate_hex.py

clean:
	rm -f dna_decimal_app.elf dna_decimal_app.bin dna_decimal_app.hex

.PHONY: all clean
