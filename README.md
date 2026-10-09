# PicoRV32-Based DNA Sequence Analyzer

A lightweight RISC-V/FPGA project combining a PicoRV32 RV32I processor with a custom Verilog RTL accelerator for DNA sequence matching and motif detection.

> **Project status:** This is a documentation starter based on the currently described design. Add your final source files and verify reported results before publishing. Six integrated simulation tests were reported as passing; check the latest XSim transcript before claiming this as verified.

## Features
- PicoRV32 processor executes C firmware.
- Custom RTL DNA accelerator controlled through memory-mapped I/O (MMIO).
- **Sequence matching:** compares two complete sequences for equal length and exact base-by-base equality.
- **Motif detection:** searches for a shorter motif inside a target sequence and reports the count and positions, including overlapping occurrences.
- Two-bit DNA encoding: A=`00`, C=`01`, G=`10`, T=`11`.
- UART input/output through a PC terminal such as PuTTY.
- Target platform: Boolean FPGA board with AMD/Xilinx Spartan-7 XC7S50.

## Architecture
1. PC/PuTTY communicates with the FPGA over UART.
2. A resident bootloader receives the application binary into application RAM.
3. PicoRV32 executes the firmware.
4. Firmware encodes the input and writes data/configuration to accelerator MMIO registers.
5. RTL performs the selected analysis.
6. Firmware reads results and prints them over UART.

See [`docs/architecture.md`](docs/architecture.md) for the described architecture and register map.

## Example test cases
| Mode | Input | Expected result |
|---|---|---|
| Sequence matching | `ACGTACGT` vs `ACGTACGT` | FOUND |
| Sequence matching | `ACGTACGT` vs `ACGTTCGT` | NOT FOUND |
| Sequence matching | `ACGT` vs `ACGTACGT` | NOT FOUND (length mismatch) |
| Motif detection | Target `ACGTACGT`, motif `ACGT` | Count 2; positions 0, 4 |
| Motif detection | Target `AAAAAAAAAA`, motif `AAA` | Count 8; positions 0–7 |
| Motif detection | Target `GGGGACGT`, motif `ACGT` | Count 1; position 4 |

See [`docs/verification.md`](docs/verification.md) for the evidence checklist.

## Reported memory configuration
- Boot ROM: 2 KB
- Application RAM: 8 KB
- Total reported instruction/data memory allocation: 10 KB
- Stated memory limit: 128 KB

This memory budget is **not** the same as FPGA resource utilization. Add the actual Vivado utilization report before publishing resource counts.

## Reported files and tools
- RTL described: `top.v`, `dna_motif_detector.v`, `dna_motif_mmio.v`
- Firmware described: `app/main.c`
- FPGA tools: Vivado and XSim
- UART settings described: 115200 baud, 8 data bits, no parity, 1 stop bit, no flow control

Confirm names and settings against the final source before release.

## Repository layout
```text
.
├── README.md
├── docs/
│   ├── architecture.md
│   └── verification.md
├── rtl/                 # Add final RTL source files here
├── app/                 # Add firmware source files here
├── constraints/         # Add final XDC files here
├── sim/                 # Add testbenches and simulation scripts here
└── .gitignore
```

## Build and run
Add verified steps for opening the Vivado project, running synthesis/implementation, running the integrated XSim testbench, building the application binary, uploading it through the bootloader, and connecting PuTTY. Use commands and paths from your working setup rather than guessed commands.

## Limitations
- The current described design performs exact sequence matching and motif detection; it is not a clinical diagnostic tool.
- Digital watermark detection is not included unless a separate watermark format and implementation are added.
- Performance improvements must be demonstrated with measured latency/cycle comparisons.
- Label physical-board results separately from simulation results.

## License
Choose a license before publishing. If you do not intend to permit reuse yet, keep the repository private until your team decides.
