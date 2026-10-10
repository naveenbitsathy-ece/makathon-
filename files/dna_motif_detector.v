// ============================================================================
// Module Name:  dna_motif_detector
// Project:      PicoRV32-Based DNA Sequence Analysis and Motif Detection
// Description:  Standalone hardware accelerator for exact DNA sequence matching
//               and motif detection.
//
// DNA Encoding:
//   A = 2'b00
//   C = 2'b01
//   G = 2'b10
//   T = 2'b11
//
// Features:
//   - Mode 0: Sequence Matching (exact whole-sequence equality comparison)
//   - Mode 1: Motif Detection (exact substring search across candidate positions)
//   - Reference / Target DNA storage: up to 128 bases (2 bits/base)
//   - Motif / Query DNA storage:     up to 128 bases (2 bits/base)
//   - Synthesizable synchronous FSM design
// ============================================================================

`timescale 1ns / 1ps

module dna_motif_detector (
    input  wire        clk,               // System clock
    input  wire        reset,             // Synchronous active-high reset
    input  wire        start,             // Start pulse / enable
    input  wire        mode,              // 0 = Sequence Matching, 1 = Motif Detection

    // Configuration inputs
    input  wire [7:0]  reference_length,  // Reference / Target sequence length (1 to 128)
    input  wire [7:0]  motif_length,      // Motif / Query sequence length (1 to 128)

    // Reference / Target Memory Write Port
    input  wire        ref_we,            // Reference write enable
    input  wire [6:0]  ref_addr,          // Reference write address [0..127]
    input  wire [1:0]  ref_din,           // Reference 2-bit base data

    // Motif / Query Memory Write Port
    input  wire        motif_we,          // Motif write enable
    input  wire [6:0]  motif_addr,        // Motif write address [0..127]
    input  wire [1:0]  motif_din,         // Motif 2-bit base data

    // Match Position Read Port
    input  wire [6:0]  match_read_addr,   // Match index to read [0..match_count-1]
    output wire [7:0]  match_read_pos,    // Starting position of the match

    // Control & Status Outputs
    output reg         busy,              // Asserted while searching
    output reg         done,              // Asserted upon search completion
    output reg  [7:0]  match_count,       // Total matches (Mode 1) or 1=FOUND/0=NOT FOUND (Mode 0)

    // Diagnostic & Waveform Signals
    output reg  [7:0]  current_position,  // Current reference candidate position
    output reg         match_found        // Pulses high when a match is recorded
);

    // ========================================================================
    // Storage Memories
    // ========================================================================
    // 1. Reference / Target DNA storage (maximum 128 bases, 2 bits per base)
    reg [1:0] ref_mem [0:127];

    // 2. Motif / Query storage (maximum 128 bases, 2 bits per base)
    reg [1:0] motif_mem [0:127];

    // 3. Match position storage (stores up to 128 match start positions)
    reg [7:0] match_pos_mem [0:127];

    // Asynchronous read for match positions
    assign match_read_pos = match_pos_mem[match_read_addr];

    // ========================================================================
    // Synchronous Memory Writes
    // ========================================================================
    always @(posedge clk) begin
        if (ref_we) begin
            ref_mem[ref_addr] <= ref_din;
        end
        if (motif_we) begin
            motif_mem[motif_addr] <= motif_din;
        end
    end

    // ========================================================================
    // FSM State Encoding
    // ========================================================================
    localparam [2:0] IDLE          = 3'd0;
    localparam [2:0] COMPARE       = 3'd1;
    localparam [2:0] CHECK         = 3'd2;
    localparam [2:0] NEXT_POSITION = 3'd3;
    localparam [2:0] SEQ_COMPARE   = 3'd4;
    localparam [2:0] SEQ_CHECK     = 3'd5;
    localparam [2:0] DONE          = 3'd6;

    reg [2:0] state;

    // Internal tracking registers
    reg [7:0] motif_idx;     // Current base index inside motif/query (0..127)
    reg       curr_mismatch; // Latches 1 if any base mismatch occurs at current pos

    // ========================================================================
    // Sequential Control Logic & Matching FSM
    // ========================================================================
    always @(posedge clk) begin
        if (reset) begin
            state            <= IDLE;
            busy             <= 1'b0;
            done             <= 1'b0;
            match_count      <= 8'd0;
            current_position <= 8'd0;
            motif_idx        <= 8'd0;
            curr_mismatch    <= 1'b0;
            match_found      <= 1'b0;
        end else begin
            case (state)
                // ------------------------------------------------------------
                // IDLE: Wait for start signal
                // ------------------------------------------------------------
                IDLE: begin
                    busy        <= 1'b0;
                    match_found <= 1'b0;

                    if (start) begin
                        done             <= 1'b0;
                        busy             <= 1'b1;
                        match_count      <= 8'd0;
                        current_position <= 8'd0;
                        motif_idx        <= 8'd0;
                        curr_mismatch    <= 1'b0;

                        if (mode == 1'b0) begin
                            // ------------------------------------------------
                            // MODE 0: Sequence Matching (Whole Sequence)
                            // ------------------------------------------------
                            if ((reference_length != motif_length) || (reference_length == 8'd0)) begin
                                // Different lengths or zero length -> immediately NOT FOUND
                                match_count <= 8'd0;
                                busy        <= 1'b0;
                                done        <= 1'b1;
                                state       <= DONE;
                            end else begin
                                state       <= SEQ_COMPARE;
                            end
                        end else begin
                            // ------------------------------------------------
                            // MODE 1: Motif Detection (Exact Substring Search)
                            // ------------------------------------------------
                            if ((reference_length < motif_length) || (motif_length == 8'd0)) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= DONE;
                            end else begin
                                state <= COMPARE;
                            end
                        end
                    end
                end

                // ------------------------------------------------------------
                // SEQ_COMPARE: Compare target and query base-by-base (Mode 0)
                // ------------------------------------------------------------
                SEQ_COMPARE: begin
                    match_found <= 1'b0;

                    if (ref_mem[motif_idx] != motif_mem[motif_idx]) begin
                        curr_mismatch <= 1'b1;
                    end

                    if (motif_idx + 1'b1 < reference_length) begin
                        motif_idx <= motif_idx + 1'b1;
                        state     <= SEQ_COMPARE;
                    end else begin
                        state     <= SEQ_CHECK;
                    end
                end

                // ------------------------------------------------------------
                // SEQ_CHECK: Evaluate whole-sequence equality result (Mode 0)
                // ------------------------------------------------------------
                SEQ_CHECK: begin
                    if (!curr_mismatch) begin
                        match_count <= 8'd1; // FOUND
                        match_found <= 1'b1;
                    end else begin
                        match_count <= 8'd0; // NOT FOUND
                        match_found <= 1'b0;
                    end
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= DONE;
                end

                // ------------------------------------------------------------
                // COMPARE: Compare motif base by base against reference (Mode 1)
                // ------------------------------------------------------------
                COMPARE: begin
                    match_found <= 1'b0;

                    // Check if current base matches
                    if (ref_mem[current_position + motif_idx] != motif_mem[motif_idx]) begin
                        curr_mismatch <= 1'b1;
                    end

                    // Check if all bases of motif have been inspected
                    if (motif_idx + 1'b1 < motif_length) begin
                        motif_idx <= motif_idx + 1'b1;
                        state     <= COMPARE;
                    end else begin
                        state     <= CHECK;
                    end
                end

                // ------------------------------------------------------------
                // CHECK: If all bases matched, record match position (Mode 1)
                // ------------------------------------------------------------
                CHECK: begin
                    // If no mismatch occurred, candidate position is a match
                    if (!curr_mismatch) begin
                        match_found                 <= 1'b1;
                        match_pos_mem[match_count]  <= current_position;
                        match_count                 <= match_count + 1'b1;
                    end else begin
                        match_found                 <= 1'b0;
                    end
                    state <= NEXT_POSITION;
                end

                // ------------------------------------------------------------
                // NEXT_POSITION: Advance candidate position or complete search (Mode 1)
                // ------------------------------------------------------------
                NEXT_POSITION: begin
                    match_found <= 1'b0;

                    // Candidate positions range from 0 to (reference_length - motif_length)
                    if (current_position + 1'b1 <= (reference_length - motif_length)) begin
                        current_position <= current_position + 1'b1;
                        motif_idx        <= 8'd0;
                        curr_mismatch    <= 1'b0;
                        state            <= COMPARE;
                    end else begin
                        state            <= DONE;
                    end
                end

                // ------------------------------------------------------------
                // DONE: Assert done flag and wait for next operation
                // ------------------------------------------------------------
                DONE: begin
                    busy        <= 1'b0;
                    done        <= 1'b1;
                    match_found <= 1'b0;

                    if (!start) begin
                        state <= IDLE;
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
