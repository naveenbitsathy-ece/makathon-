// ============================================================================
// Module Name:  dna_motif_mmio
// Project:      PicoRV32-Based DNA Sequence Analysis and Motif Detection
// Description:  MMIO Bus Wrapper connecting PicoRV32 memory interface to the
//               standalone dna_motif_detector accelerator.
//
// Address Map (DNA_BASE = 0x40000000):
//   0x40000000 : REF_DATA       (W) - Write reference DNA data (16 bases/word)
//   0x40000004 : MOTIF_DATA     (W) - Write motif DNA data (16 bases/word)
//   0x40000008 : CONFIG         (W/R) - [7:0]=ref_len, [12:8]=motif_len
//   0x4000000C : CONTROL        (W/R) - bit 0=START, bit 1=RESET_POINTERS
//   0x40000010 : STATUS         (R) - bit 0=BUSY, bit 1=DONE
//   0x40000014 : MATCH_COUNT    (R) - Total matches detected [7:0]
//   0x40000018 : POSITION_INDEX (W/R) - Desired match index [6:0]
//   0x4000001C : POSITION_DATA  (R) - Starting position for POSITION_INDEX [7:0]
//
// DNA Encoding:
//   A = 2'b00, C = 2'b01, G = 2'b10, T = 2'b11
// Packing Convention:
//   bits [1:0]   = base 0 (first base)
//   bits [3:2]   = base 1
//   ...
//   bits [31:30] = base 15 (sixteenth base)
// ============================================================================

`timescale 1ns / 1ps

module dna_motif_mmio (
    input  wire        clk,
    input  wire        reset,

    // PicoRV32 Memory / MMIO Bus Interface
    input  wire        mem_valid,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg         mem_ready,
    output reg  [31:0] mem_rdata,

    // Control & Configuration Interface to dna_motif_detector
    output reg         start,
    output reg         op_mode,           // 0 = Sequence Matching, 1 = Motif Detection
    output reg  [7:0]  reference_length,
    output reg  [7:0]  motif_length,

    // Reference Memory Write Port (to dna_motif_detector)
    output reg         ref_we,
    output reg  [6:0]  ref_addr,
    output reg  [1:0]  ref_din,

    // Motif Memory Write Port (to dna_motif_detector)
    output reg         motif_we,
    output reg  [6:0]  motif_addr,
    output reg  [1:0]  motif_din,

    // Match Position Read Port (to dna_motif_detector)
    output reg  [6:0]  match_read_addr,
    input  wire [7:0]  match_read_pos,

    // Status Inputs from dna_motif_detector
    input  wire        busy,
    input  wire        done,
    input  wire [7:0]  match_count,

    // Diagnostic output for monitoring
    output reg  [6:0]  position_index
);

    // ========================================================================
    // Register Address Map Definitions
    // ========================================================================
    localparam [31:0] ADDR_REF_DATA       = 32'h4000_0000;
    localparam [31:0] ADDR_MOTIF_DATA     = 32'h4000_0004;
    localparam [31:0] ADDR_CONFIG         = 32'h4000_0008;
    localparam [31:0] ADDR_CONTROL        = 32'h4000_000C;
    localparam [31:0] ADDR_STATUS         = 32'h4000_0010;
    localparam [31:0] ADDR_MATCH_COUNT    = 32'h4000_0014;
    localparam [31:0] ADDR_POSITION_INDEX = 32'h4000_0018;
    localparam [31:0] ADDR_POSITION_DATA  = 32'h4000_001C;

    // ========================================================================
    // Internal FSM and Pointers
    // ========================================================================
    localparam [1:0] S_IDLE        = 2'd0;
    localparam [1:0] S_WRITE_REF   = 2'd1;
    localparam [1:0] S_WRITE_MOTIF = 2'd2;

    reg [1:0]  state;
    reg [3:0]  sub_cnt;       // Sub-index counter (0..15) for base unpacking
    reg [31:0] latched_wdata; // Latched write data for bursting
    reg [6:0]  ref_ptr;       // Current base pointer in ref_mem (0..127)
    reg [6:0]  motif_ptr;     // Current base pointer in motif_mem (0..127)

    // ========================================================================
    // MMIO State Machine and Register Handling
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            mem_ready        <= 1'b0;
            mem_rdata        <= 32'd0;
            start            <= 1'b0;
            op_mode          <= 1'b1;      // Default: 1 = Motif Detection
            reference_length <= 8'd0;
            motif_length     <= 8'd0;
            ref_we           <= 1'b0;
            ref_addr         <= 7'd0;
            ref_din          <= 2'd0;
            motif_we         <= 1'b0;
            motif_addr       <= 7'd0;
            motif_din        <= 2'd0;
            match_read_addr  <= 7'd0;
            position_index   <= 7'd0;
            ref_ptr          <= 7'd0;
            motif_ptr        <= 7'd0;
            sub_cnt          <= 4'd0;
            latched_wdata    <= 32'd0;
        end else begin
            // Default single-cycle pulse resets
            mem_ready <= 1'b0;
            start     <= 1'b0;
            ref_we    <= 1'b0;
            motif_we  <= 1'b0;

            case (state)
                // ------------------------------------------------------------
                // S_IDLE: Handle MMIO Read / Write Requests
                // ------------------------------------------------------------
                S_IDLE: begin
                    if (mem_valid && !mem_ready) begin
                        if (|mem_wstrb) begin
                            // ------------------------------------------------
                            // WRITE TRANSACTIONS
                            // ------------------------------------------------
                            case (mem_addr)
                                ADDR_REF_DATA: begin
                                    // Start sequential write of 16 bases into ref_mem
                                    latched_wdata <= mem_wdata;
                                    sub_cnt       <= 4'd0;
                                    ref_we        <= 1'b1;
                                    ref_addr      <= ref_ptr;
                                    ref_din       <= mem_wdata[1:0];
                                    state         <= S_WRITE_REF;
                                end

                                ADDR_MOTIF_DATA: begin
                                    // Start sequential write of 16 bases into motif_mem
                                    latched_wdata <= mem_wdata;
                                    sub_cnt       <= 4'd0;
                                    motif_we      <= 1'b1;
                                    motif_addr    <= motif_ptr;
                                    motif_din     <= mem_wdata[1:0];
                                    state         <= S_WRITE_MOTIF;
                                end

                                ADDR_CONFIG: begin
                                    if (mem_wstrb[0]) reference_length <= mem_wdata[7:0];
                                    if (mem_wstrb[1]) motif_length     <= mem_wdata[15:8];
                                    mem_ready <= 1'b1;
                                end

                                ADDR_CONTROL: begin
                                    if (mem_wdata[0]) begin
                                        start     <= 1'b1; // 1-cycle pulse to detector
                                        ref_ptr   <= 7'd0; // Auto-reset write pointers
                                        motif_ptr <= 7'd0;
                                    end
                                    if (mem_wdata[1]) begin
                                        ref_ptr   <= 7'd0; // Explicit pointer reset
                                        motif_ptr <= 7'd0;
                                    end
                                    if (|mem_wstrb) begin
                                        op_mode   <= mem_wdata[2]; // Bit 2: 0=Sequence Matching, 1=Motif Detection
                                    end
                                    mem_ready <= 1'b1;
                                end

                                ADDR_POSITION_INDEX: begin
                                    position_index  <= mem_wdata[6:0];
                                    match_read_addr <= mem_wdata[6:0];
                                    mem_ready       <= 1'b1;
                                end

                                default: begin
                                    if (mem_addr >= 32'h4000_0000 && mem_addr <= 32'h4000_001C) begin
                                        mem_ready <= 1'b1;
                                    end
                                end
                            endcase
                        end else begin
                            // ------------------------------------------------
                            // READ TRANSACTIONS
                            // ------------------------------------------------
                            case (mem_addr)
                                ADDR_STATUS: begin
                                    mem_rdata <= {30'd0, done, busy};
                                    mem_ready <= 1'b1;
                                end

                                ADDR_MATCH_COUNT: begin
                                    mem_rdata <= {24'd0, match_count};
                                    mem_ready <= 1'b1;
                                end

                                ADDR_POSITION_INDEX: begin
                                    mem_rdata <= {25'd0, position_index};
                                    mem_ready <= 1'b1;
                                end

                                ADDR_POSITION_DATA: begin
                                    mem_rdata <= {24'd0, match_read_pos};
                                    mem_ready <= 1'b1;
                                end

                                ADDR_CONFIG: begin
                                    mem_rdata <= {16'd0, motif_length, reference_length};
                                    mem_ready <= 1'b1;
                                end

                                ADDR_CONTROL: begin
                                    mem_rdata <= {29'd0, op_mode, 1'b0, start};
                                    mem_ready <= 1'b1;
                                end

                                default: begin
                                    if (mem_addr >= 32'h4000_0000 && mem_addr <= 32'h4000_001C) begin
                                        mem_rdata <= 32'd0;
                                        mem_ready <= 1'b1;
                                    end
                                end
                            endcase
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_WRITE_REF: Sequentially write 16 bases to ref_mem
                // ------------------------------------------------------------
                S_WRITE_REF: begin
                    if (sub_cnt == 4'd15) begin
                        // Final base registered in ref_mem
                        ref_we    <= 1'b0;
                        ref_ptr   <= ref_ptr + 7'd16;
                        mem_ready <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        sub_cnt  <= sub_cnt + 1'b1;
                        ref_we   <= 1'b1;
                        ref_addr <= ref_ptr + (sub_cnt + 1'b1);
                        ref_din  <= latched_wdata[((sub_cnt + 1'b1) * 2) +: 2];
                    end
                end

                // ------------------------------------------------------------
                // S_WRITE_MOTIF: Sequentially write 16 bases to motif_mem
                // ------------------------------------------------------------
                S_WRITE_MOTIF: begin
                    if (sub_cnt == 4'd15) begin
                        // Final base registered in motif_mem
                        motif_we  <= 1'b0;
                        motif_ptr <= motif_ptr + 7'd16;
                        mem_ready <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        sub_cnt    <= sub_cnt + 1'b1;
                        motif_we   <= 1'b1;
                        motif_addr <= motif_ptr + (sub_cnt + 1'b1);
                        motif_din  <= latched_wdata[((sub_cnt + 1'b1) * 2) +: 2];
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
