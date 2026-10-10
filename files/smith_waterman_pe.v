// =============================================================================
// File: smith_waterman_pe.v
// Module: smith_waterman_pe
// Description:
//   Processing Element (PE) for the Smith-Waterman Local Sequence Alignment.
//   Parameterized by:
//     - SCORE_WIDTH: N-bit width of dynamic programming scores (e.g. 8, 16, 32)
//     - CHAR_WIDTH:  Bit width of character representation (e.g. 8 for ASCII)
//     - MATCH_SCORE: Bonus for match (e.g. 3)
//     - MISMATCH_PENALTY: Penalty for mismatch (e.g. 3)
//     - GAP_PENALTY: Penalty for gap (e.g. 2)
//
//   Recurrence:
//     H(i, j) = max( 0,
//                    H(i-1, j-1) + S(A_i, B_j),
//                    H(i-1, j)   - GAP_PENALTY,
//                    H(i, j-1)   - GAP_PENALTY )
//
//   Arithmetic:
//     Signed arithmetic with SCORE_WIDTH + 1 bits prevents underflow when
//     penalties exceed current scores, cleanly clamping negative values to 0.
// =============================================================================

`timescale 1ns / 1ps

module smith_waterman_pe #(
    parameter SCORE_WIDTH                  = 16,
    parameter CHAR_WIDTH                   = 8,
    parameter [SCORE_WIDTH-1:0] MATCH_SCORE      = 3,
    parameter [SCORE_WIDTH-1:0] MISMATCH_PENALTY = 3,
    parameter [SCORE_WIDTH-1:0] GAP_PENALTY      = 2
)(
    input  wire                   is_match,
    input  wire [SCORE_WIDTH-1:0] diag_score,
    input  wire [SCORE_WIDTH-1:0] up_score,
    input  wire [SCORE_WIDTH-1:0] left_score,
    output wire [SCORE_WIDTH-1:0] out_score,
    output wire [1:0]             direction
);

    // Direction encoding
    localparam DIR_STOP = 2'b00;
    localparam DIR_DIAG = 2'b01;
    localparam DIR_UP   = 2'b10;
    localparam DIR_LEFT = 2'b11;

// Signed terms: SCORE_WIDTH + 1 bits (includes positive leading 0 for unsigned input)
    wire signed [SCORE_WIDTH:0] s_match_term = $signed({1'b0, MATCH_SCORE});
    wire signed [SCORE_WIDTH:0] s_mism_term  = $signed({1'b0, MISMATCH_PENALTY});
    wire signed [SCORE_WIDTH:0] s_gap_term   = $signed({1'b0, GAP_PENALTY});

    wire signed [SCORE_WIDTH:0] s_diag_in    = $signed({1'b0, diag_score});
    wire signed [SCORE_WIDTH:0] s_up_in      = $signed({1'b0, up_score});
    wire signed [SCORE_WIDTH:0] s_left_in    = $signed({1'b0, left_score});

    // 1. Parallel comparator: up vs left directly from register inputs
    // GAP_PENALTY cancels: (up_score - 2 >= left_score - 2) <=> (up_score >= left_score)
    wire c_ul = (up_score >= left_score);

    // 2. Arithmetic branches
    wire signed [SCORE_WIDTH:0] s_diag_match = s_diag_in + s_match_term;
    wire signed [SCORE_WIDTH:0] s_diag_mism  = s_diag_in - s_mism_term;
    wire signed [SCORE_WIDTH:0] s_diag       = is_match ? s_diag_match : s_diag_mism;
    wire signed [SCORE_WIDTH:0] s_up         = s_up_in   - s_gap_term;
    wire signed [SCORE_WIDTH:0] s_left       = s_left_in - s_gap_term;

    // 3. Select best between up and left using early c_ul decision
    wire signed [SCORE_WIDTH:0] best_up_left = c_ul ? s_up : s_left;

    // 4. Single comparison: diag vs best_up_left
    wire diag_wins = (s_diag >= best_up_left);

    // 5. Select candidate maximum
    wire signed [SCORE_WIDTH:0] max_val = diag_wins ? s_diag : best_up_left;

    // 6. Smith-Waterman clamp to 0 (sign bit indicates negative; eliminates 17-bit comparator carry chain)
    assign out_score = max_val[SCORE_WIDTH] ? {SCORE_WIDTH{1'b0}} : max_val[SCORE_WIDTH-1:0];

    // 7. Traceback direction using wide-NOR for zero detection to avoid CARRY4 inference
    wire is_zero = max_val[SCORE_WIDTH] || ~(|max_val[SCORE_WIDTH-1:0]);

    assign direction = is_zero   ? DIR_STOP :
                       diag_wins ? DIR_DIAG :
                       c_ul      ? DIR_UP   :
                                   DIR_LEFT;

endmodule
