// =============================================================================
// File: smith_waterman_core.v
// Module: smith_waterman_core
// Description:
//   Fully parameterizable N-bit Smith-Waterman Local Sequence Alignment Core.
//   Features:
//     - Parameterized score width (SCORE_WIDTH = N bits, e.g. 8, 16, 32)
//     - Parameterized sequence lengths (MAX_LEN_A, MAX_LEN_B)
//     - Parallel Wavefront Dynamic Programming evaluation:
//       Computes anti-diagonals (i + j = k) in parallel, completing the
//       entire DP matrix in only (len_a + len_b - 1) clock cycles.
//     - Real-time global maximum score and coordinate tracking.
//     - Integrated hardware traceback engine to extract optimal local alignment.
//     - Matrix read port for inspecting any cell (i, j) in the DP table.
// =============================================================================

`timescale 1ns / 1ps

module smith_waterman_core #(
    parameter SCORE_WIDTH                  = 16, // N-bit score data width
    parameter CHAR_WIDTH                   = 8,  // Character bit-width (8 for ASCII)
    parameter MAX_LEN_A                    = 8,  // Maximum length of sequence A
    parameter MAX_LEN_B                    = 8,  // Maximum length of sequence B
    parameter [SCORE_WIDTH-1:0] MATCH_SCORE      = 3,  // Reward for matching characters
    parameter [SCORE_WIDTH-1:0] MISMATCH_PENALTY = 3,  // Penalty for mismatch
    parameter [SCORE_WIDTH-1:0] GAP_PENALTY      = 2   // Linear gap penalty
)(
    input  wire                                     clk,
    input  wire                                     rst_n,
    
    // Control interface
    input  wire                                     start,
    output reg                                      busy,
    output reg                                      done,
    
    // Sequence inputs (packed MSB-first: char 1 at MSB byte)
    input  wire [MAX_LEN_A * CHAR_WIDTH - 1 : 0]    seq_a,
    input  wire [MAX_LEN_B * CHAR_WIDTH - 1 : 0]    seq_b,
    input  wire [$clog2(MAX_LEN_A + 1) - 1 : 0]     len_a,
    input  wire [$clog2(MAX_LEN_B + 1) - 1 : 0]     len_b,
    
    // Peak alignment results
    output reg  [SCORE_WIDTH - 1 : 0]               max_score,
    output reg  [$clog2(MAX_LEN_A + 1) - 1 : 0]     max_pos_i,
    output reg  [$clog2(MAX_LEN_B + 1) - 1 : 0]     max_pos_j,
    
    // Traceback alignment outputs
    output reg  [$clog2(MAX_LEN_A + MAX_LEN_B + 1) - 1 : 0] aln_len,
    output reg  [(MAX_LEN_A + MAX_LEN_B) * CHAR_WIDTH - 1 : 0] aln_a,
    output reg  [(MAX_LEN_A + MAX_LEN_B) * CHAR_WIDTH - 1 : 0] aln_b,
    
    // Memory/matrix inspection interface
    input  wire [$clog2(MAX_LEN_A + 1) - 1 : 0]     read_row,
    input  wire [$clog2(MAX_LEN_B + 1) - 1 : 0]     read_col,
    output wire [SCORE_WIDTH - 1 : 0]               read_score,
    output wire [1 : 0]                             read_dir
);

    localparam MAX_ALN_LEN    = MAX_LEN_A + MAX_LEN_B;
    localparam LEN_A_BITS     = $clog2(MAX_LEN_A + 1);
    localparam LEN_B_BITS     = $clog2(MAX_LEN_B + 1);
    localparam ALN_LEN_BITS   = $clog2(MAX_ALN_LEN + 1);
    localparam DIAG_STEP_BITS = $clog2(MAX_LEN_A + MAX_LEN_B + 2);

    // Direction constants
    localparam DIR_STOP = 2'b00;
    localparam DIR_DIAG = 2'b01;
    localparam DIR_UP   = 2'b10;
    localparam DIR_LEFT = 2'b11;

    // FSM States
    localparam S_IDLE        = 4'd0;
    localparam S_COMPUTE     = 4'd1;
    localparam S_MAX_C1      = 4'd2; // Col reduction level 1: 8 -> 4
    localparam S_MAX_C2      = 4'd3; // Col reduction level 2: 4 -> 2
    localparam S_MAX_C3      = 4'd4; // Col reduction level 3: 2 -> 1 (row winners)
    localparam S_MAX_R1      = 4'd5; // Row reduction level 1: 8 -> 4
    localparam S_MAX_R2      = 4'd6; // Row reduction level 2: 4 -> 2
    localparam S_MAX_R3      = 4'd7; // Row reduction level 3: 2 -> 1 (global winner)
    localparam S_TRACE_SETUP = 4'd8;
    localparam S_TRACEBACK   = 4'd9;
    localparam S_REVERSE     = 4'd10;
    localparam S_DONE        = 4'd11;

    reg [3:0] state;

    // Latched sequence characters: 1-indexed [1 : MAX_LEN] with max_fanout for physical replication
    (* max_fanout = 16 *) reg [CHAR_WIDTH - 1 : 0] char_a_reg [1 : MAX_LEN_A];
    (* max_fanout = 16 *) reg [CHAR_WIDTH - 1 : 0] char_b_reg [1 : MAX_LEN_B];
    reg [LEN_A_BITS - 1 : 0] len_a_reg;
    reg [LEN_B_BITS - 1 : 0] len_b_reg;

    // DP Matrix storage: (MAX_LEN_A + 1) x (MAX_LEN_B + 1)
    reg [SCORE_WIDTH - 1 : 0] score_matrix [0 : MAX_LEN_A][0 : MAX_LEN_B];
    reg [1 : 0]              dir_matrix   [0 : MAX_LEN_A][0 : MAX_LEN_B];

    // Precomputed character equality match matrix (1 bit per cell)
    // Preserved with DONT_TOUCH to ensure registered flip-flops drive PEs with 0 ns comparator delay
    (* DONT_TOUCH = "yes", KEEP = "true" *) reg [MAX_LEN_B : 1] match_matrix [1 : MAX_LEN_A];

    // Pipelined maximum-score search registers (each level is a registered single-comparator stage)
    reg [SCORE_WIDTH - 1 : 0] col_l1_s [1 : MAX_LEN_A][0 : 3];
    reg [LEN_B_BITS - 1 : 0]  col_l1_c [1 : MAX_LEN_A][0 : 3];

    reg [SCORE_WIDTH - 1 : 0] col_l2_s [1 : MAX_LEN_A][0 : 1];
    reg [LEN_B_BITS - 1 : 0]  col_l2_c [1 : MAX_LEN_A][0 : 1];

    reg [SCORE_WIDTH - 1 : 0] row_max_score [1 : MAX_LEN_A];
    reg [LEN_B_BITS - 1 : 0]  row_max_pos_j [1 : MAX_LEN_A];

    reg [SCORE_WIDTH - 1 : 0] row_l1_s [0 : 3];
    reg [LEN_A_BITS - 1 : 0]  row_l1_r [0 : 3];
    reg [LEN_B_BITS - 1 : 0]  row_l1_c [0 : 3];

    reg [SCORE_WIDTH - 1 : 0] row_l2_s [0 : 1];
    reg [LEN_A_BITS - 1 : 0]  row_l2_r [0 : 1];
    reg [LEN_B_BITS - 1 : 0]  row_l2_c [0 : 1];

    // Wavefront anti-diagonal counter (k = i + j)
    reg [DIAG_STEP_BITS - 1 : 0] diag_step;

    // Traceback registers
    reg [LEN_A_BITS - 1 : 0]   tb_i;
    reg [LEN_B_BITS - 1 : 0]   tb_j;
    reg [ALN_LEN_BITS - 1 : 0] tb_step;
    reg [ALN_LEN_BITS - 1 : 0] tb_total_len;
    reg [CHAR_WIDTH - 1 : 0]   raw_aln_a [0 : MAX_ALN_LEN - 1];
    reg [CHAR_WIDTH - 1 : 0]   raw_aln_b [0 : MAX_ALN_LEN - 1];

    // Processing Element array wires
    wire [SCORE_WIDTH-1:0] pe_score [1 : MAX_LEN_A][1 : MAX_LEN_B];
    wire [1:0]             pe_dir   [1 : MAX_LEN_A][1 : MAX_LEN_B];

    // Instantiate PEs across the dynamic programming grid
    genvar gi, gj;
    generate
        for (gi = 1; gi <= MAX_LEN_A; gi = gi + 1) begin : GEN_ROW
            for (gj = 1; gj <= MAX_LEN_B; gj = gj + 1) begin : GEN_COL
                smith_waterman_pe #(
                    .SCORE_WIDTH(SCORE_WIDTH),
                    .CHAR_WIDTH(CHAR_WIDTH),
                    .MATCH_SCORE(MATCH_SCORE),
                    .MISMATCH_PENALTY(MISMATCH_PENALTY),
                    .GAP_PENALTY(GAP_PENALTY)
                ) pe_inst (
                    .is_match   (match_matrix[gi][gj]),
                    .diag_score (score_matrix[gi-1][gj-1]),
                    .up_score   (score_matrix[gi-1][gj]),
                    .left_score (score_matrix[gi][gj-1]),
                    .out_score  (pe_score[gi][gj]),
                    .direction  (pe_dir[gi][gj])
                );
            end
        end
    endgenerate

    // Readout port
    assign read_score = score_matrix[read_row][read_col];
    assign read_dir   = dir_matrix[read_row][read_col];

    // Loop variables for procedural blocks
    integer r, c, k;

    // Helper task to initialize computation
    task init_computation;
        begin
            done        <= 1'b0;
            busy        <= 1'b1;
            len_a_reg   <= len_a;
            len_b_reg   <= len_b;
            max_score   <= {SCORE_WIDTH{1'b0}};
            max_pos_i   <= {LEN_A_BITS{1'b0}};
            max_pos_j   <= {LEN_B_BITS{1'b0}};
            aln_len     <= {ALN_LEN_BITS{1'b0}};
            aln_a       <= {MAX_ALN_LEN * CHAR_WIDTH{1'b0}};
            aln_b       <= {MAX_ALN_LEN * CHAR_WIDTH{1'b0}};
            diag_step   <= 2; // Anti-diagonal starts at 1 + 1 = 2

            for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                row_max_score[r] <= {SCORE_WIDTH{1'b0}};
                row_max_pos_j[r] <= {LEN_B_BITS{1'b0}};
            end

            for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                char_a_reg[r] <= seq_a[(MAX_LEN_A - r + 1)*CHAR_WIDTH - 1 -: CHAR_WIDTH];
            end
            for (c = 1; c <= MAX_LEN_B; c = c + 1) begin
                char_b_reg[c] <= seq_b[(MAX_LEN_B - c + 1)*CHAR_WIDTH - 1 -: CHAR_WIDTH];
            end

            for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                for (c = 1; c <= MAX_LEN_B; c = c + 1) begin
                    match_matrix[r][c] <= (seq_a[(MAX_LEN_A - r + 1)*CHAR_WIDTH - 1 -: CHAR_WIDTH] == seq_b[(MAX_LEN_B - c + 1)*CHAR_WIDTH - 1 -: CHAR_WIDTH]);
                end
            end

            for (r = 0; r <= MAX_LEN_A; r = r + 1) begin
                for (c = 0; c <= MAX_LEN_B; c = c + 1) begin
                    score_matrix[r][c] <= {SCORE_WIDTH{1'b0}};
                    dir_matrix[r][c]   <= DIR_STOP;
                end
            end
            state <= S_COMPUTE;
        end
    endtask

    // Main Control and Datapath FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            max_score    <= {SCORE_WIDTH{1'b0}};
            max_pos_i    <= {LEN_A_BITS{1'b0}};
            max_pos_j    <= {LEN_B_BITS{1'b0}};
            aln_len      <= {ALN_LEN_BITS{1'b0}};
            aln_a        <= {MAX_ALN_LEN * CHAR_WIDTH{1'b0}};
            aln_b        <= {MAX_ALN_LEN * CHAR_WIDTH{1'b0}};
            diag_step    <= 0;
            tb_i         <= 0;
            tb_j         <= 0;
            tb_step      <= 0;
            tb_total_len <= 0;
            len_a_reg    <= 0;
            len_b_reg    <= 0;

            for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                row_max_score[r] <= {SCORE_WIDTH{1'b0}};
                row_max_pos_j[r] <= {LEN_B_BITS{1'b0}};
                for (c = 0; c < 4; c = c + 1) begin
                    col_l1_s[r][c] <= {SCORE_WIDTH{1'b0}};
                    col_l1_c[r][c] <= {LEN_B_BITS{1'b0}};
                end
                for (c = 0; c < 2; c = c + 1) begin
                    col_l2_s[r][c] <= {SCORE_WIDTH{1'b0}};
                    col_l2_c[r][c] <= {LEN_B_BITS{1'b0}};
                end
            end

            for (r = 0; r < 4; r = r + 1) begin
                row_l1_s[r] <= {SCORE_WIDTH{1'b0}};
                row_l1_r[r] <= {LEN_A_BITS{1'b0}};
                row_l1_c[r] <= {LEN_B_BITS{1'b0}};
            end
            for (r = 0; r < 2; r = r + 1) begin
                row_l2_s[r] <= {SCORE_WIDTH{1'b0}};
                row_l2_r[r] <= {LEN_A_BITS{1'b0}};
                row_l2_c[r] <= {LEN_B_BITS{1'b0}};
            end

            for (r = 1; r <= MAX_LEN_A; r = r + 1)
                char_a_reg[r] <= {CHAR_WIDTH{1'b0}};
            for (c = 1; c <= MAX_LEN_B; c = c + 1)
                char_b_reg[c] <= {CHAR_WIDTH{1'b0}};

            for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                for (c = 1; c <= MAX_LEN_B; c = c + 1) begin
                    match_matrix[r][c] <= 1'b0;
                end
            end

            for (r = 0; r <= MAX_LEN_A; r = r + 1) begin
                for (c = 0; c <= MAX_LEN_B; c = c + 1) begin
                    score_matrix[r][c] <= {SCORE_WIDTH{1'b0}};
                    dir_matrix[r][c]   <= DIR_STOP;
                end
            end
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        init_computation();
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_COMPUTE: begin
                    // Parallel anti-diagonal cell update
                    // In clock cycle diag_step, all cells (r, c) where r + c == diag_step
                    // latch their PE outputs simultaneously.
                    for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                        for (c = 1; c <= MAX_LEN_B; c = c + 1) begin
                            if ((r + c) == diag_step && r <= len_a_reg && c <= len_b_reg) begin
                                score_matrix[r][c] <= pe_score[r][c];
                                dir_matrix[r][c]   <= pe_dir[r][c];
                            end
                        end
                    end

                    // Check if all anti-diagonals have finished
                    if (diag_step == (len_a_reg + len_b_reg)) begin
                        state <= S_MAX_C1;
                    end else begin
                        diag_step <= diag_step + 1'b1;
                    end
                end

                S_MAX_C1: begin
                    // Col Level 1 reduction: 8 columns -> 4 pairs (1 comparator per pair)
                    for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                        col_l1_s[r][0] <= (score_matrix[r][2] > score_matrix[r][1]) ? score_matrix[r][2] : score_matrix[r][1];
                        col_l1_c[r][0] <= (score_matrix[r][2] > score_matrix[r][1]) ? 4'd2 : 4'd1;

                        col_l1_s[r][1] <= (score_matrix[r][4] > score_matrix[r][3]) ? score_matrix[r][4] : score_matrix[r][3];
                        col_l1_c[r][1] <= (score_matrix[r][4] > score_matrix[r][3]) ? 4'd4 : 4'd3;

                        col_l1_s[r][2] <= (score_matrix[r][6] > score_matrix[r][5]) ? score_matrix[r][6] : score_matrix[r][5];
                        col_l1_c[r][2] <= (score_matrix[r][6] > score_matrix[r][5]) ? 4'd6 : 4'd5;

                        col_l1_s[r][3] <= (score_matrix[r][8] > score_matrix[r][7]) ? score_matrix[r][8] : score_matrix[r][7];
                        col_l1_c[r][3] <= (score_matrix[r][8] > score_matrix[r][7]) ? 4'd8 : 4'd7;
                    end
                    state <= S_MAX_C2;
                end

                S_MAX_C2: begin
                    // Col Level 2 reduction: 4 pairs -> 2 pairs (1 comparator per pair)
                    for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                        col_l2_s[r][0] <= (col_l1_s[r][1] > col_l1_s[r][0]) ? col_l1_s[r][1] : col_l1_s[r][0];
                        col_l2_c[r][0] <= (col_l1_s[r][1] > col_l1_s[r][0]) ? col_l1_c[r][1] : col_l1_c[r][0];

                        col_l2_s[r][1] <= (col_l1_s[r][3] > col_l1_s[r][2]) ? col_l1_s[r][3] : col_l1_s[r][2];
                        col_l2_c[r][1] <= (col_l1_s[r][3] > col_l1_s[r][2]) ? col_l1_c[r][3] : col_l1_c[r][2];
                    end
                    state <= S_MAX_C3;
                end

                S_MAX_C3: begin
                    // Col Level 3 reduction: 2 pairs -> 1 row winner (1 comparator)
                    for (r = 1; r <= MAX_LEN_A; r = r + 1) begin
                        row_max_score[r] <= (col_l2_s[r][1] > col_l2_s[r][0]) ? col_l2_s[r][1] : col_l2_s[r][0];
                        row_max_pos_j[r] <= (col_l2_s[r][1] > col_l2_s[r][0]) ? col_l2_c[r][1] : col_l2_c[r][0];
                    end
                    state <= S_MAX_R1;
                end

                S_MAX_R1: begin
                    // Row Level 1 reduction: 8 rows -> 4 pairs (1 comparator per pair)
                    row_l1_s[0] <= (row_max_score[2] > row_max_score[1]) ? row_max_score[2] : row_max_score[1];
                    row_l1_r[0] <= (row_max_score[2] > row_max_score[1]) ? 4'd2 : 4'd1;
                    row_l1_c[0] <= (row_max_score[2] > row_max_score[1]) ? row_max_pos_j[2] : row_max_pos_j[1];

                    row_l1_s[1] <= (row_max_score[4] > row_max_score[3]) ? row_max_score[4] : row_max_score[3];
                    row_l1_r[1] <= (row_max_score[4] > row_max_score[3]) ? 4'd4 : 4'd3;
                    row_l1_c[1] <= (row_max_score[4] > row_max_score[3]) ? row_max_pos_j[4] : row_max_pos_j[3];

                    row_l1_s[2] <= (row_max_score[6] > row_max_score[5]) ? row_max_score[6] : row_max_score[5];
                    row_l1_r[2] <= (row_max_score[6] > row_max_score[5]) ? 4'd6 : 4'd5;
                    row_l1_c[2] <= (row_max_score[6] > row_max_score[5]) ? row_max_pos_j[6] : row_max_pos_j[5];

                    row_l1_s[3] <= (row_max_score[8] > row_max_score[7]) ? row_max_score[8] : row_max_score[7];
                    row_l1_r[3] <= (row_max_score[8] > row_max_score[7]) ? 4'd8 : 4'd7;
                    row_l1_c[3] <= (row_max_score[8] > row_max_score[7]) ? row_max_pos_j[8] : row_max_pos_j[8];

                    state <= S_MAX_R2;
                end

                S_MAX_R2: begin
                    // Row Level 2 reduction: 4 pairs -> 2 pairs (1 comparator per pair)
                    row_l2_s[0] <= (row_l1_s[1] > row_l1_s[0]) ? row_l1_s[1] : row_l1_s[0];
                    row_l2_r[0] <= (row_l1_s[1] > row_l1_s[0]) ? row_l1_r[1] : row_l1_r[0];
                    row_l2_c[0] <= (row_l1_s[1] > row_l1_s[0]) ? row_l1_c[1] : row_l1_c[0];

                    row_l2_s[1] <= (row_l1_s[3] > row_l1_s[2]) ? row_l1_s[3] : row_l1_s[2];
                    row_l2_r[1] <= (row_l1_s[3] > row_l1_s[2]) ? row_l1_r[3] : row_l1_r[2];
                    row_l2_c[1] <= (row_l1_s[3] > row_l1_s[2]) ? row_l1_c[3] : row_l1_c[2];

                    state <= S_MAX_R3;
                end

                S_MAX_R3: begin
                    // Row Level 3 reduction: 2 pairs -> 1 global winner (1 comparator)
                    if (row_l2_s[1] > row_l2_s[0]) begin
                        max_score <= row_l2_s[1];
                        max_pos_i <= (row_l2_s[1] > 0) ? row_l2_r[1] : {LEN_A_BITS{1'b0}};
                        max_pos_j <= (row_l2_s[1] > 0) ? row_l2_c[1] : {LEN_B_BITS{1'b0}};
                    end else begin
                        max_score <= row_l2_s[0];
                        max_pos_i <= (row_l2_s[0] > 0) ? row_l2_r[0] : {LEN_A_BITS{1'b0}};
                        max_pos_j <= (row_l2_s[0] > 0) ? row_l2_c[0] : {LEN_B_BITS{1'b0}};
                    end
                    state <= S_TRACE_SETUP;
                end

                S_TRACE_SETUP: begin
                    if (max_score == {SCORE_WIDTH{1'b0}}) begin
                        // No positive local alignment score
                        aln_len <= 0;
                        state   <= S_DONE;
                    end else begin
                        tb_i    <= max_pos_i;
                        tb_j    <= max_pos_j;
                        tb_step <= 0;
                        state   <= S_TRACEBACK;
                    end
                end

                S_TRACEBACK: begin
                    // Local alignment termination condition
                    if (tb_i == 0 || tb_j == 0 ||
                        score_matrix[tb_i][tb_j] == {SCORE_WIDTH{1'b0}} ||
                        dir_matrix[tb_i][tb_j] == DIR_STOP ||
                        tb_step >= MAX_ALN_LEN) begin
                        
                        tb_total_len <= tb_step;
                        state        <= S_REVERSE;
                    end else begin
                        case (dir_matrix[tb_i][tb_j])
                            DIR_DIAG: begin
                                raw_aln_a[tb_step] <= char_a_reg[tb_i];
                                raw_aln_b[tb_step] <= char_b_reg[tb_j];
                                tb_i               <= tb_i - 1'b1;
                                tb_j               <= tb_j - 1'b1;
                            end

                            DIR_UP: begin
                                raw_aln_a[tb_step] <= char_a_reg[tb_i];
                                raw_aln_b[tb_step] <= 8'h2D; // ASCII '-'
                                tb_i               <= tb_i - 1'b1;
                            end

                            DIR_LEFT: begin
                                raw_aln_a[tb_step] <= 8'h2D; // ASCII '-'
                                raw_aln_b[tb_step] <= char_b_reg[tb_j];
                                tb_j               <= tb_j - 1'b1;
                            end

                            default: begin
                                tb_total_len <= tb_step;
                                state        <= S_REVERSE;
                            end
                        endcase
                        tb_step <= tb_step + 1'b1;
                    end
                end

                S_REVERSE: begin
                    // Reverse from traceback (peak-to-start) to standard (start-to-end) format
                    aln_len <= tb_total_len;
                    for (k = 0; k < MAX_ALN_LEN; k = k + 1) begin
                        if (k < tb_total_len) begin
                            aln_a[(MAX_ALN_LEN - k)*CHAR_WIDTH - 1 -: CHAR_WIDTH] <= raw_aln_a[tb_total_len - 1 - k];
                            aln_b[(MAX_ALN_LEN - k)*CHAR_WIDTH - 1 -: CHAR_WIDTH] <= raw_aln_b[tb_total_len - 1 - k];
                        end else begin
                            aln_a[(MAX_ALN_LEN - k)*CHAR_WIDTH - 1 -: CHAR_WIDTH] <= {CHAR_WIDTH{1'b0}};
                            aln_b[(MAX_ALN_LEN - k)*CHAR_WIDTH - 1 -: CHAR_WIDTH] <= {CHAR_WIDTH{1'b0}};
                        end
                    end
                    state <= S_DONE;
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    if (start) begin
                        init_computation();
                    end else begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
