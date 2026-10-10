`timescale 1 ns / 1 ps

// ==============================================================================
// Top-Level SoC: system
// Includes PicoRV32 Core + Unified Memory (Code + Data) + Memory-Mapped Output
// ==============================================================================

module system (
    input            clk,
    input            resetn,
    output           trap,
    output reg [7:0] out_byte,
    output reg       out_byte_en
);
    // 4096 32-bit words = 16 KB Unified Memory
    parameter MEM_SIZE = 4096;
    parameter FAST_MEMORY = 1;

    // PicoRV32 Native Memory Interface
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    // Look-ahead interface
    wire        mem_la_read;
    wire        mem_la_write;
    wire [31:0] mem_la_addr;
    wire [31:0] mem_la_wdata;
    wire [3:0]  mem_la_wstrb;



ila_0 ila_inst (
    .clk(clk),
    .probe0(out_byte),
    .probe1(out_byte_en),
    .probe2(trap)
);
    // --------------------------------------------------------------------------
    // PicoRV32 CPU Core Instantiation
    // --------------------------------------------------------------------------
    picorv32 #(
        .ENABLE_COUNTERS     (1),
        .ENABLE_COUNTERS64   (1),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA   (0),
        .TWO_STAGE_SHIFT     (0),
        .BARREL_SHIFTER      (0),
        .TWO_CYCLE_COMPARE   (0),
        .TWO_CYCLE_ALU       (0),
        .CATCH_MISALIGN      (1),
        .CATCH_ILLINSN       (1),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (0),
        .ENABLE_FAST_MUL     (0),
        .ENABLE_DIV          (0),
        .ENABLE_IRQ          (0),
        .ENABLE_IRQ_QREGS    (0)
    ) picorv32_core (
        .clk         (clk         ),
        .resetn      (resetn      ),
        .trap        (trap        ),
        .mem_valid   (mem_valid   ),
        .mem_instr   (mem_instr   ),
        .mem_ready   (mem_ready   ),
        .mem_addr    (mem_addr    ),
        .mem_wdata   (mem_wdata   ),
        .mem_wstrb   (mem_wstrb   ),
        .mem_rdata   (mem_rdata   ),
        .mem_la_read (mem_la_read ),
        .mem_la_write(mem_la_write),
        .mem_la_addr (mem_la_addr ),
        .mem_la_wdata(mem_la_wdata),
        .mem_la_wstrb(mem_la_wstrb)
    );

    // --------------------------------------------------------------------------
    // Unified Memory Array: 16 KB (4096 x 32-bit words)
    // --------------------------------------------------------------------------
    reg [31:0] memory [0:MEM_SIZE-1];

    // Variables for simulation .bin reading
    integer bin_file;
    integer byte_idx;
    reg [7:0] raw_byte;

    // --------------------------------------------------------------------------
    // INITIAL BEGIN: Unified Memory Initialization
    // --------------------------------------------------------------------------
    initial begin
        // Step 1: Pre-clear memory to 0
        for (byte_idx = 0; byte_idx < MEM_SIZE; byte_idx = byte_idx + 1) begin
            memory[byte_idx] = 32'h00000000;
        end

`ifndef SYNTHESIS
        // Step 2A: For Simulation / Testbench - Load raw .bin file directly
        bin_file = $fopen("hello.bin", "rb");
        if (bin_file != 0) begin
            $display("[SYSTEM] Loading hello.bin directly into unified memory...");
            byte_idx = 0;
            while (!$feof(bin_file) && (byte_idx < (MEM_SIZE * 4))) begin
                if ($fread(raw_byte, bin_file) == 1) begin
                    // Pack bytes into 32-bit words in RISC-V Little-Endian order
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
            $display("[SYSTEM] Successfully loaded %0d bytes from hello.bin", byte_idx);
        end else begin
            $display("[SYSTEM] hello.bin not found. Trying hello.hex via $readmemh...");
            $readmemh("hello.hex", memory);
        end
`else
        // Step 2B: For Vivado Synthesis (FPGA Block RAM Initialization)
        // Vivado requires $readmemh with hex words to initialize BRAMs
        $readmemh("hello.hex", memory);
`endif
    end

    // --------------------------------------------------------------------------
    // Memory Controller & Memory-Mapped IO (MMIO at 0x10000000)
    // --------------------------------------------------------------------------
    generate if (FAST_MEMORY) begin
        always @(posedge clk) begin
            mem_ready   <= 1;
            out_byte_en <= 0;
            mem_rdata   <= memory[mem_la_addr >> 2];

            // Memory Write
            if (mem_la_write && (mem_la_addr >> 2) < MEM_SIZE) begin
                if (mem_la_wstrb[0]) memory[mem_la_addr >> 2][ 7: 0] <= mem_la_wdata[ 7: 0];
                if (mem_la_wstrb[1]) memory[mem_la_addr >> 2][15: 8] <= mem_la_wdata[15: 8];
                if (mem_la_wstrb[2]) memory[mem_la_addr >> 2][23:16] <= mem_la_wdata[23:16];
                if (mem_la_wstrb[3]) memory[mem_la_addr >> 2][31:24] <= mem_la_wdata[31:24];
            end
            // MMIO Output (printf / putchar to 0x1000_0000)
            else if (mem_la_write && mem_la_addr == 32'h1000_0000) begin
                out_byte_en <= 1;
                out_byte    <= mem_la_wdata[7:0];
            end
        end
    end else begin
        reg [31:0] m_read_data;
        reg m_read_en;

        always @(posedge clk) begin
            m_read_en   <= 0;
            mem_ready   <= mem_valid && !mem_ready && m_read_en;
            m_read_data <= memory[mem_addr >> 2];
            mem_rdata   <= m_read_data;
            out_byte_en <= 0;

            case (1)
                mem_valid && !mem_ready && !mem_wstrb && (mem_addr >> 2) < MEM_SIZE: begin
                    m_read_en <= 1;
                end
                mem_valid && !mem_ready && |mem_wstrb && (mem_addr >> 2) < MEM_SIZE: begin
                    if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                    if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                    if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
                    mem_ready <= 1;
                end
                mem_valid && !mem_ready && |mem_wstrb && mem_addr == 32'h1000_0000: begin
                    out_byte_en <= 1;
                    out_byte    <= mem_wdata[7:0];
                    mem_ready   <= 1;
                end
            endcase
        end
    end endgenerate

endmodule
