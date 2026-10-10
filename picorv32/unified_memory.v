`timescale 1 ns / 1 ps

// ==============================================================================
// Module: unified_memory
// Description: 32-bit Unified RAM (Instruction + Data) for PicoRV32
//
// Demonstrates loading compiled C code (hello.bin / hello.hex) into memory:
// 1. Simulation: Directly reads raw binary 'hello.bin' byte-by-byte using $fread
//    and packs into 32-bit words respecting RISC-V Little-Endian format.
// 2. Synthesis (Vivado): Uses $readmemh("hello.hex", memory) which Vivado embeds
//    directly into FPGA Block RAMs during bitstream generation.
// ==============================================================================

module unified_memory #(
    parameter MEM_SIZE = 4096  // Number of 32-bit words (4096 words = 16 KB)
)(
    input             clk,
    input             wen,           // Write enable
    input      [3:0]  wstrb,         // Byte write strobes
    input      [31:0] addr,          // Word-aligned address (byte_addr >> 2)
    input      [31:0] wdata,         // Write data
    output reg [31:0] rdata          // Read data (synchronous)
);

    // Memory array: 4096 words x 32 bits = 16 KB unified memory
    reg [31:0] memory [0:MEM_SIZE-1];

    // Variables for simulation file reading
    integer bin_file;
    integer byte_idx;
    integer words_read;
    reg [7:0] raw_byte;

    // ==========================================================================
    // Unified Memory Initialization (hello.bin / hello.hex)
    // ==========================================================================
    initial begin
        // 1. Clear memory with 0s (or RISC-V NOP: 32'h00000013)
        for (byte_idx = 0; byte_idx < MEM_SIZE; byte_idx = byte_idx + 1) begin
            memory[byte_idx] = 32'h00000000;
        end

`ifndef SYNTHESIS
        // ----------------------------------------------------------------------
        // SIMULATION ONLY: Direct loading from raw binary 'hello.bin' via $fread
        // ----------------------------------------------------------------------
        // Note: RISC-V is Little-Endian!
        // We read byte-by-byte and pack into 32-bit words:
        // byte 0 -> [7:0], byte 1 -> [15:8], byte 2 -> [23:16], byte 3 -> [31:24]
        // ----------------------------------------------------------------------
        bin_file = $fopen("hello.bin", "rb");
        if (bin_file != 0) begin
            $display("[MEM INIT] Successfully opened hello.bin for unified memory.");
            byte_idx = 0;
            while (!$feof(bin_file) && (byte_idx < (MEM_SIZE * 4))) begin
                if ($fread(raw_byte, bin_file) == 1) begin
                    case (byte_idx % 4)
                        2'd0: memory[byte_idx >> 2][ 7: 0] = raw_byte;
                        2'd1: memory[byte_idx >> 2][15: 8] = raw_byte;
                        2'd2: memory[byte_idx >> 2][23:16] = raw_byte;
                        2'd3: memory[byte_idx >> 2][31:24] = raw_byte;
                    endcase
                    byte_idx = byte_idx + 1;
                end
            end
            $fclose(bin_file);
            $display("[MEM INIT] Loaded %0d bytes (%0d 32-bit words) from hello.bin", 
                     byte_idx, (byte_idx + 3) / 4);
        end else begin
            $display("[MEM INIT] 'hello.bin' not found. Falling back to 'hello.hex' via $readmemh...");
            $readmemh("hello.hex", memory);
        end
`else
        // ----------------------------------------------------------------------
        // VIVADO SYNTHESIS: Block RAM Initialization
        // ----------------------------------------------------------------------
        // Vivado synthesis does NOT execute $fread. It requires $readmemh
        // to populate BRAM primitives (RAMB36E1 / RAMB18E1) in the bitstream.
        // Convert hello.bin to hello.hex using: python bin2hex.py hello.bin hello.hex
        // ----------------------------------------------------------------------
        $readmemh("hello.hex", memory);
`endif
    end

    // ==========================================================================
    // Synchronous Read / Write Ports
    // ==========================================================================
    always @(posedge clk) begin
        // Read port
        if (addr < MEM_SIZE) begin
            rdata <= memory[addr];
        end else begin
            rdata <= 32'h00000000;
        end

        // Write port with byte enable strobes
        if (wen && (addr < MEM_SIZE)) begin
            if (wstrb[0]) memory[addr][ 7: 0] <= wdata[ 7: 0];
            if (wstrb[1]) memory[addr][15: 8] <= wdata[15: 8];
            if (wstrb[2]) memory[addr][23:16] <= wdata[23:16];
            if (wstrb[3]) memory[addr][31:24] <= wdata[31:24];
        end
    end

endmodule
