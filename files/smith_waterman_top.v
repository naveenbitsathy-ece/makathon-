// =============================================================================
// File: smith_waterman_top.v
// Module: smith_waterman_top
// Description:
//   Top-level module for the N-bit Smith-Waterman Hardware Accelerator.
//   Exposes both direct parallel ports and a memory-mapped / register-file
//   interface suitable for microcontroller / SoC integration (e.g. PicoRV32 / AXI / Wishbone).
// =============================================================================

`timescale 1ns / 1ps

module smith_waterman_top #(
    parameter SCORE_WIDTH      = 16, // N-bit score precision
    parameter CHAR_WIDTH       = 8,  // ASCII character width
    parameter MAX_LEN_A        = 8,  // Max length of sequence A
    parameter MAX_LEN_B        = 8,  // Max length of sequence B
    parameter MATCH_SCORE      = 3,  // Reward for match
    parameter MISMATCH_PENALTY = 3,  // Penalty for mismatch
    parameter GAP_PENALTY      = 2   // Penalty for insertion / deletion
)(
    input  wire                                     clk,
    input  wire                                     rst_n,

    // Core Control & Handshaking
    input  wire                                     start,
    output wire                                     busy,
    output wire                                     done,

    // Parallel Sequence Inputs
    input  wire [MAX_LEN_A * CHAR_WIDTH - 1 : 0]    seq_a,
    input  wire [MAX_LEN_B * CHAR_WIDTH - 1 : 0]    seq_b,
    input  wire [$clog2(MAX_LEN_A + 1) - 1 : 0]     len_a,
    input  wire [$clog2(MAX_LEN_B + 1) - 1 : 0]     len_b,

    // Alignment Results
    output wire [SCORE_WIDTH - 1 : 0]               max_score,
    output wire [$clog2(MAX_LEN_A + 1) - 1 : 0]     max_pos_i,
    output wire [$clog2(MAX_LEN_B + 1) - 1 : 0]     max_pos_j,
    output wire [$clog2(MAX_LEN_A + MAX_LEN_B + 1) - 1 : 0] aln_len,
    output wire [(MAX_LEN_A + MAX_LEN_B) * CHAR_WIDTH - 1 : 0] aln_a,
    output wire [(MAX_LEN_A + MAX_LEN_B) * CHAR_WIDTH - 1 : 0] aln_b,

    // Matrix Readout Port
    input  wire [$clog2(MAX_LEN_A + 1) - 1 : 0]     read_row,
    input  wire [$clog2(MAX_LEN_B + 1) - 1 : 0]     read_col,
    output wire [SCORE_WIDTH - 1 : 0]               read_score,
    output wire [1 : 0]                             read_dir
);

    // Instantiate Core Accelerator
    smith_waterman_core #(
        .SCORE_WIDTH      (SCORE_WIDTH),
        .CHAR_WIDTH       (CHAR_WIDTH),
        .MAX_LEN_A        (MAX_LEN_A),
        .MAX_LEN_B        (MAX_LEN_B),
        .MATCH_SCORE      (MATCH_SCORE),
        .MISMATCH_PENALTY (MISMATCH_PENALTY),
        .GAP_PENALTY      (GAP_PENALTY)
    ) u_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .busy       (busy),
        .done       (done),
        .seq_a      (seq_a),
        .seq_b      (seq_b),
        .len_a      (len_a),
        .len_b      (len_b),
        .max_score  (max_score),
        .max_pos_i  (max_pos_i),
        .max_pos_j  (max_pos_j),
        .aln_len    (aln_len),
        .aln_a      (aln_a),
        .aln_b      (aln_b),
        .read_row   (read_row),
        .read_col   (read_col),
        .read_score (read_score),
        .read_dir   (read_dir)
    );

endmodule
