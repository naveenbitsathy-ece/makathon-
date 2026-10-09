# Architecture

## Overview
The project integrates a PicoRV32 RV32I processor with a custom Verilog RTL DNA-analysis accelerator on a Boolean FPGA (Spartan-7 XC7S50).

The PicoRV32 executes C firmware. The firmware receives input through UART, encodes DNA bases, configures the accelerator through memory-mapped I/O (MMIO), reads results, and reports them over UART.

## Main blocks
- **PicoRV32:** Executes firmware and coordinates operations.
- **Boot ROM (reported 2 KB):** Holds the resident bootloader.
- **Application RAM (reported 8 KB):** Holds the uploaded application.
- **UART:** Serial communication with a PC terminal such as PuTTY.
- **DNA accelerator:** Custom RTL for full-sequence matching and motif detection.
- **MMIO interface:** Exposes configuration, control, status, count, and position registers.
- **LED controller:** Provides visible status indicators.

## DNA encoding
| Base | 2-bit encoding |
|---|---|
| A | `00` |
| C | `01` |
| G | `10` |
| T | `11` |

A 128-base sequence requires 256 bits (32 bytes) at two bits per base.

## Operating modes
1. **Sequence matching (mode 0):** Checks whether two complete sequences have equal lengths and identical bases at every position.
2. **Motif detection (mode 1):** Searches a target sequence for a shorter motif and reports its occurrence count and starting positions. Overlapping matches are intended to be supported.

## Reported MMIO register map
| Address | Register | Purpose |
|---|---|---|
| `0x40000000` | Target data | Target/reference sequence data |
| `0x40000004` | Query/motif data | Query or motif data |
| `0x40000008` | Configuration | Target and query/motif lengths |
| `0x4000000C` | Control | START bit 0; mode bit 2 |
| `0x40000010` | Status | Accelerator status |
| `0x40000014` | Match count | Number of matches |
| `0x40000018` | Position index | Selects a match position |
| `0x4000001C` | Position data | Selected match position |

**Integration note:** Confirm the data-word loading/indexing mechanism, status-bit meanings, and register behavior against the final RTL before treating this table as a formal interface specification. Do not call the interface AXI-Lite unless the RTL actually implements AXI-Lite.

## Memory budget
Reported instruction/data memory allocation: 2 KB boot ROM + 8 KB application RAM = 10 KB, under a 128 KB limit. Peripheral MMIO space is separate from that RAM allocation. This is not the FPGA LUT/FF/BRAM utilization report.
