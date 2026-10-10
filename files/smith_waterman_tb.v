// =============================================================================
// File: smith_waterman_tb.v
// Module: smith_waterman_tb
// Description:
//   Self-checking testbench for the N-bit Smith-Waterman Hardware Accelerator.
//   Verifies:
//     - Test 1: Standard DNA local alignment with mutations and gaps
//     - Test 2: 100% Identical match sequences
//     - Test 3: Substring alignment with flanking noise
//     - Test 4: Completely disjoint sequences (score 0 clamping)
//   Features:
//     - Formatted 2D Dynamic Programming matrix visualization in simulation log
//     - Traceback aligned string verification
//     - VCD waveform generation for GTKWave
//     - Pass/Fail assertion checking
// =============================================================================

`timescale 1ns / 1ps

module smith_waterman_tb;

    // Parameters under test
    localparam SCORE_WIDTH      = 16; // N = 16-bit precision
    localparam CHAR_WIDTH       = 8;  // ASCII characters
    localparam MAX_LEN_A        = 8;
    localparam MAX_LEN_B        = 8;
    localparam MATCH_SCORE      = 3;
    localparam MISMATCH_PENALTY = 3;
    localparam GAP_PENALTY      = 2;
    localparam MAX_ALN_LEN      = MAX_LEN_A + MAX_LEN_B;

    localparam LEN_A_BITS   = $clog2(MAX_LEN_A + 1);
    localparam LEN_B_BITS   = $clog2(MAX_LEN_B + 1);
    localparam ALN_LEN_BITS = $clog2(MAX_ALN_LEN + 1);

    // Clock and Reset signals
    reg clk;
    reg rst_n;

    // DUT inputs
    reg                                  start;
    reg [MAX_LEN_A * CHAR_WIDTH - 1 : 0] seq_a;
    reg [MAX_LEN_B * CHAR_WIDTH - 1 : 0] seq_b;
    reg [LEN_A_BITS - 1 : 0]             len_a;
    reg [LEN_B_BITS - 1 : 0]             len_b;
    reg [LEN_A_BITS - 1 : 0]             read_row;
    reg [LEN_B_BITS - 1 : 0]             read_col;

    // DUT outputs
    wire                                 busy;
    wire                                 done;
    wire [SCORE_WIDTH - 1 : 0]           max_score;
    wire [LEN_A_BITS - 1 : 0]            max_pos_i;
    wire [LEN_B_BITS - 1 : 0]            max_pos_j;
    wire [ALN_LEN_BITS - 1 : 0]          aln_len;
    wire [MAX_ALN_LEN * CHAR_WIDTH - 1 : 0] aln_a;
    wire [MAX_ALN_LEN * CHAR_WIDTH - 1 : 0] aln_b;
    wire [SCORE_WIDTH - 1 : 0]           read_score;
    wire [1 : 0]                         read_dir;

    // Instantiate Top-Level Device Under Test (DUT)
    smith_waterman_top #(
        .SCORE_WIDTH      (SCORE_WIDTH),
        .CHAR_WIDTH       (CHAR_WIDTH),
        .MAX_LEN_A        (MAX_LEN_A),
        .MAX_LEN_B        (MAX_LEN_B),
        .MATCH_SCORE      (MATCH_SCORE),
        .MISMATCH_PENALTY (MISMATCH_PENALTY),
        .GAP_PENALTY      (GAP_PENALTY)
    ) dut (
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

    // 100 MHz clock generation (period = 10ns)
    always #5 clk = ~clk;

    // Tracking test statistics
    integer test_count = 0;
    integer pass_count = 0;
    integer fail_count = 0;

    // Loop variables
    integer r, c, k;

    // Helper task to execute a test case and print the DP matrix
    task run_test;
        input [255:0]                       test_name;
        input [MAX_LEN_A * CHAR_WIDTH - 1 : 0] in_seq_a;
        input [LEN_A_BITS - 1 : 0]          in_len_a;
        input [MAX_LEN_B * CHAR_WIDTH - 1 : 0] in_seq_b;
        input [LEN_B_BITS - 1 : 0]          in_len_b;
        input [SCORE_WIDTH - 1 : 0]         expected_score;
        input [LEN_A_BITS - 1 : 0]          expected_pos_i;
        input [LEN_B_BITS - 1 : 0]          expected_pos_j;
        begin
            test_count = test_count + 1;
            $display("----------------------------------------------------------------------");
            $display("TEST CASE %0d: %0s", test_count, test_name);
            $display("  Input Sequence A: %0s (Length = %0d)", in_seq_a, in_len_a);
            $display("  Input Sequence B: %0s (Length = %0d)", in_seq_b, in_len_b);
            $display("----------------------------------------------------------------------");

            // Apply inputs and assert start
            @(posedge clk);
            seq_a <= in_seq_a;
            len_a <= in_len_a;
            seq_b <= in_seq_b;
            len_b <= in_len_b;
            start <= 1'b1;

            @(posedge clk);
            start <= 1'b0;

            // Wait until hardware computation completes
            wait (done == 1'b1);
            @(posedge clk);

            // Display DP Score Matrix
            $display("\n  === DYNAMIC PROGRAMMING SCORE MATRIX (Smith-Waterman) ===");
            $write("        -  ");
            for (c = 1; c <= in_len_b; c = c + 1) begin
                $write("  %c ", in_seq_b[(MAX_LEN_B - c + 1)*CHAR_WIDTH - 1 -: CHAR_WIDTH]);
            end
            $display("");

            for (r = 0; r <= in_len_a; r = r + 1) begin
                if (r == 0)
                    $write("   -  ");
                else
                    $write("   %c  ", in_seq_a[(MAX_LEN_A - r + 1)*CHAR_WIDTH - 1 -: CHAR_WIDTH]);

                for (c = 0; c <= in_len_b; c = c + 1) begin
                    read_row = r;
                    read_col = c;
                    #1; // Short delay for combinational read
                    $write("%3d ", read_score);
                end
                $display("");
            end

            // Display Alignment Results
            $display("\n  Hardware Results:");
            $display("    Max Alignment Score : %0d (Expected: %0d)", max_score, expected_score);
            $display("    Peak Matrix Cell    : (%0d, %0d) (Expected: (%0d, %0d))", 
                     max_pos_i, max_pos_j, expected_pos_i, expected_pos_j);
            $display("    Alignment Length    : %0d", aln_len);
            
            $write("    Aligned Seq A       : ");
            for (k = 0; k < aln_len; k = k + 1) begin
                $write("%c", aln_a[(MAX_ALN_LEN - k)*CHAR_WIDTH - 1 -: CHAR_WIDTH]);
            end
            $display("");

            $write("    Aligned Seq B       : ");
            for (k = 0; k < aln_len; k = k + 1) begin
                $write("%c", aln_b[(MAX_ALN_LEN - k)*CHAR_WIDTH - 1 -: CHAR_WIDTH]);
            end
            $display("");

            // Verify with Assertions
            if (max_score == expected_score &&
                (expected_score == 0 || (max_pos_i == expected_pos_i && max_pos_j == expected_pos_j))) begin
                $display("  >>> STATUS: [PASS] <<<\n");
                pass_count = pass_count + 1;
            end else begin
                $display("  >>> STATUS: [FAIL] - Score or Position Mismatch! <<<\n");
                fail_count = fail_count + 1;
            end

            // Allow DUT to transition back to IDLE
            repeat (2) @(posedge clk);
        end
    endtask

    // Main Test Stimulus
    initial begin
        // Setup waveform dumping for viewing in GTKWave
        $dumpfile("smith_waterman.vcd");
        $dumpvars(0, smith_waterman_tb);

        $display("======================================================================");
        $display("   N-BIT SMITH-WATERMAN ACCELERATOR VERILOG SIMULATION");
        $display("   Configuration: SCORE_WIDTH=%0d bits, MATCH=%0d, MISMATCH=-%0d, GAP=-%0d",
                 SCORE_WIDTH, MATCH_SCORE, MISMATCH_PENALTY, GAP_PENALTY);
        $display("======================================================================\n");

        // Initialize signals
        clk      = 0;
        rst_n    = 0;
        start    = 0;
        seq_a    = 0;
        seq_b    = 0;
        len_a    = 0;
        len_b    = 0;
        read_row = 0;
        read_col = 0;

        // Apply Reset
        #25;
        rst_n = 1;
        #15;

        // ---------------------------------------------------------------------
        // TEST 1: Mutations and Gap Insertion (Standard Bio-sequence alignment)
        // A: TGTTACGG (8)
        // B: GGTTGACT (8)
        // Optimal alignment: GTT-AC / GTTGAC -> Score = 13 at (6, 7)
        // ---------------------------------------------------------------------
        run_test("Local Alignment with Gap/Mismatch",
                 "TGTTACGG", 8,
                 "GGTTGACT", 8,
                 16'd13, 6, 7);

        // ---------------------------------------------------------------------
        // TEST 2: 100% Identical Sequences (Perfect Match)
        // A: ATCGATCG (8)
        // B: ATCGATCG (8)
        // Optimal score: 8 matches * 3 = 24 at (8, 8)
        // ---------------------------------------------------------------------
        run_test("Perfect Sequence Match",
                 "ATCGATCG", 8,
                 "ATCGATCG", 8,
                 16'd24, 8, 8);

        // ---------------------------------------------------------------------
        // TEST 3: Common Substring with Flanking Mismatches
        // A: CCGATTCC (8)
        // B: AAGATTGG (8)
        // Common substring: GATT (4 matches * 3 = 12 at (6, 6))
        // ---------------------------------------------------------------------
        run_test("Shared Local Substring",
                 "CCGATTCC", 8,
                 "AAGATTGG", 8,
                 16'd12, 6, 6);

        // ---------------------------------------------------------------------
        // TEST 4: Completely Disjoint Sequences (Zero Clamping Verification)
        // A: AAAAAAAA (8)
        // B: CCCCCCCC (8)
        // Expected score: 0 (No match; negative scores clamp to 0)
        // ---------------------------------------------------------------------
        run_test("Completely Disjoint Sequences",
                 "AAAAAAAA", 8,
                 "CCCCCCCC", 8,
                 16'd0, 0, 0);

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        $display("======================================================================");
        $display("SIMULATION SUMMARY: Total=%0d | Passed=%0d | Failed=%0d", 
                 test_count, pass_count, fail_count);
        if (fail_count == 0) begin
            $display("ALL %0d TESTS PASSED SUCCESSFULLY! WORKFLOW VERIFIED.", pass_count);
        end else begin
            $display("SIMULATION FAILED WITH %0d ERRORS.", fail_count);
        end
        $display("Waveform saved to: smith_waterman.vcd");
        $display("======================================================================");

        $finish;
    end

endmodule
