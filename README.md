# 🧬 PicoRV32-Based DNA Sequence Analyzer

### A RISC-V and FPGA-Accelerated DNA Sequence Matching and Motif Detection System

An FPGA-based DNA analysis project integrating the lightweight **PicoRV32 RISC-V processor**, custom Verilog RTL hardware accelerators, and C firmware to perform DNA sequence matching and motif detection.

The project demonstrates how embedded processors and custom digital hardware can work together to accelerate sequence-processing tasks.

---

## 📌 Project Overview

DNA sequences consist of four nucleotide bases:

- **A** — Adenine
- **C** — Cytosine
- **G** — Guanine
- **T** — Thymine

This project represents DNA bases digitally, processes them using a custom RTL accelerator, and reports analysis results through a UART interface.

The PicoRV32 processor executes the firmware, configures the accelerator through Memory-Mapped I/O (MMIO), and communicates results to a PC.

## 🎯 Project Objectives

- Integrate the PicoRV32 RV32I processor with a custom DNA analysis accelerator.
- Implement DNA sequence matching using Verilog RTL.
- Implement motif detection and overlapping match counting.
- Interface processor firmware and hardware using MMIO registers.
- Support serial communication between a PC and FPGA.
- Verify the design using Verilog testbenches and XSim simulation.
- Demonstrate hardware/software co-design on an FPGA development board.

## ✨ Key Features

- **RISC-V Processing:** Executes C firmware using PicoRV32.
- **DNA Sequence Matching:** Checks whether two sequences are identical, including length validation.
- **DNA Motif Detection:** Searches for a shorter DNA pattern within a target sequence.
- **Overlapping Matches:** Counts overlapping motif occurrences when supported by the implementation.
- **Compact DNA Encoding:** Represents each DNA base using two bits.
- **Memory-Mapped Interface:** Connects the processor to the custom accelerator.
- **UART Communication:** Supports PC-to-FPGA input and FPGA-to-PC result reporting through the implemented serial interface.
- **Simulation-Based Verification:** Uses Verilog testbenches and XSim to test design behavior.

## 🧬 DNA Encoding

Each DNA base is represented using two bits.

| DNA Base | Binary Encoding |
|---|---|
| A | `00` |
| C | `01` |
| G | `10` |
| T | `11` |

For example:

```text
DNA Sequence: A C G T
Binary Data:  00 01 10 11
```

Two-bit encoding reduces the storage required for DNA sequence data compared with storing each nucleotide as a full ASCII character.

## 🏗️ System Architecture

```text
                 PC / Terminal
                       |
                  UART Interface
                       |
                       v
              UART RX/TX Peripheral
                       |
                       v
              PicoRV32 RISC-V CPU
                       |
                C Firmware / Driver
                       |
                 MMIO Interface
                       |
                       v
             DNA Analysis Accelerator
                  (Verilog RTL)
                       |
             +---------+---------+
             |                   |
             v                   v
      Sequence Matching     Motif Detection
             |                   |
             +---------+---------+
                       |
                  Result Registers
                       |
                       v
                 PicoRV32 CPU
                       |
                  UART TX
                       |
                       v
                 PC / Terminal
```

The actual UART peripheral, memory map, and accelerator connections must match the final integrated RTL and firmware.

## ⚙️ Operating Modes

### 1. DNA Sequence Matching

Compares two complete DNA sequences.

The sequences are considered a match when their lengths are equal and all corresponding bases are identical.

**Example:**

```text
Sequence 1: ACGTACGT
Sequence 2: ACGTACGT
Result: MATCH FOUND
```

```text
Sequence 1: ACGTACGT
Sequence 2: ACGTTCGT
Result: MATCH NOT FOUND
```

```text
Sequence 1: ACGT
Sequence 2: ACGTACGT
Result: MATCH NOT FOUND
Reason: Length mismatch
```

### 2. DNA Motif Detection

Searches for a shorter DNA pattern inside a target sequence and reports the number of occurrences and their positions.

**Example 1: Multiple motif occurrences**

```text
Target Sequence: ACGTACGT
Motif:           ACGT

Match Count: 2
Match Positions: 0, 4
```

**Example 2: Overlapping matches**

```text
Target Sequence: AAAAAAAAAA
Motif:           AAA

Match Count: 8
Match Positions: 0, 1, 2, 3, 4, 5, 6, 7
```

Positions in these examples use zero-based indexing. Confirm that the implemented accelerator supports overlapping matches and reports positions using this convention.

## 🔧 Hardware and Software Components

| Component | Purpose |
|---|---|
| PicoRV32 | Lightweight RV32I processor |
| Verilog RTL | Hardware description for the processor system and accelerator |
| DNA Motif Detector | Performs motif-search operations |
| DNA MMIO Controller | Provides processor-accessible control and result registers |
| C Firmware | Receives input, configures hardware, and reports results |
| UART Interface | Transfers requests and responses between PC and FPGA |
| Vivado | FPGA synthesis, implementation, and bitstream generation |
| XSim | RTL simulation and verification |
| Testbenches | Verify functional behavior and integration |

## 🗂️ Repository Structure

```text
Makathon_new/
├── app/                       # Application firmware
├── picorv32/                  # PicoRV32 processor source
├── picorv32_bootloader/       # Bootloader source
├── picorv32_bootloader_proj/  # Bootloader FPGA project
├── rtl/                       # RTL modules
├── sim_integrated_proj/       # Integrated simulation project
├── smith_waterman/            # Sequence-alignment experiments
├── host/                      # Host-side utilities
├── docs/                      # Project documentation
├── top.v                      # Top-level system RTL
├── system.v                   # Processor/system integration
├── dna_motif_detector.v       # DNA motif detection logic
├── dna_motif_mmio.v           # DNA accelerator MMIO interface
├── picorv32.v                 # PicoRV32 processor RTL
├── tb_integrated_dna_soc.v    # Integrated system testbench
├── build.tcl                  # Build script
├── run_integrated_sim.tcl     # Simulation script
├── README.md                  # Project documentation
└── .gitignore                 # Generated-file exclusions
```

*This structure is representative. Verify filenames and directories against the files committed to the repository.*

## 🧪 Verification and Testing

The project uses Verilog testbenches and XSim simulation to evaluate the behavior of the DNA accelerator and integrated processor system.

| Test | Input | Expected Behavior |
|---|---|---|
| Identical sequences | `ACGTACGT` vs `ACGTACGT` | Match found |
| Different sequences | `ACGTACGT` vs `ACGTTCGT` | No match |
| Different lengths | `ACGT` vs `ACGTACGT` | No match |
| Multiple motif occurrences | Target `ACGTACGT`, motif `ACGT` | 2 matches |
| Overlapping motif occurrences | Target `AAAAAAAAAA`, motif `AAA` | 8 matches |
| Single motif occurrence | Target `GGGGACGT`, motif `ACGT` | 1 match |

These are expected functional results. Report simulation or hardware tests as passed only after checking the latest simulation transcript or actual FPGA output.

## 🧠 Memory Configuration

The currently described design uses the following reported memory budget:

| Memory Component | Reported Size |
|---|---:|
| Boot ROM | 2 KB |
| Application RAM | 8 KB |
| Total reported allocation | 10 KB |
| Stated memory limit | 128 KB |

These values describe the reported memory configuration and should be verified against the final RTL and linker configuration. Memory allocation is not the same as FPGA LUT, flip-flop, or BRAM utilization.

## 🚀 Development Workflow

The intended development and verification workflow is:

1. Develop and integrate the PicoRV32 processor and DNA accelerator RTL.
2. Develop C firmware to configure the accelerator and process requests.
3. Build the firmware binary and memory initialization files.
4. Run RTL simulation using XSim and the integrated testbench.
5. Synthesize and implement the design using Vivado.
6. Review timing, design-rule checks, and FPGA utilization reports.
7. Generate and program the FPGA bitstream.
8. Connect the PC through the configured UART interface.
9. Submit DNA sequences and verify the returned results.

Use the actual project scripts and board-specific constraints from this repository when executing these steps.

## 🛠️ Tools and Technologies

- **Hardware Description:** Verilog HDL
- **Processor Architecture:** RISC-V RV32I
- **Processor Core:** PicoRV32
- **Firmware:** C
- **FPGA Design:** AMD/Xilinx Vivado
- **Simulation:** XSim
- **Communication:** UART
- **Hardware Interface:** Memory-Mapped I/O (MMIO)
- **Version Control:** Git and GitHub

### Target FPGA Platform

The currently described target is a Boolean FPGA development board using an AMD/Xilinx Spartan-7 XC7S50 FPGA.

Confirm the exact board model, FPGA part number, clock constraints, and pin assignments against the final hardware setup before programming the device.

## 📊 Performance Evaluation

The project can be evaluated using:

- Sequence length and motif length.
- Number of detected motif occurrences.
- Functional correctness against a software reference model.
- Processing latency and processor clock cycles.
- FPGA LUT, flip-flop, and BRAM utilization.
- Maximum supported sequence size.
- UART communication reliability.

Include actual measurements from simulation or hardware testing before making performance claims.

## 🔮 Future Enhancements

- Develop a browser-based interface for uploading DNA datasets.
- Generate random DNA sequences with a user-defined base count.
- Support manual sequence entry and interactive result visualization.
- Connect a Python backend to the FPGA through USB-UART.
- Export analysis results to CSV or JSON.
- Explore more advanced sequence-alignment algorithms such as Smith–Waterman.
- Optimize accelerator performance and FPGA resource utilization.

Advanced algorithms should be described as implemented features only after their RTL and verification are complete.

## ⚠️ Limitations

- The described core functions are exact sequence matching and DNA motif detection.
- More advanced alignment functionality depends on the corresponding implementation.
- A website-based interface requires compatible firmware, UART hardware, and a communication protocol.
- Performance and FPGA resource claims require measured evidence.
- This project is intended for educational and engineering demonstration, not clinical diagnosis.

## 📚 Documentation

See the `docs/` directory for architecture, register-map, build, and verification documentation where available.

## 👥 Team

Developed as an electronics and communication engineering project focused on RISC-V processor integration, FPGA acceleration, and digital hardware design.

Add your team members, institutional details, and individual contributions before final submission.

## 📄 License

Choose and add an appropriate open-source license before permitting others to reuse or redistribute this project. Ensure that the licensing terms of any third-party source code, including PicoRV32, are respected.
