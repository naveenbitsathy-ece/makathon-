// ============================================================================
// Testbench:    tb_dna_regression.v
// Project:      DNA Sequence Analyzer & Motif Detection Accelerator
// Description:  Comprehensive hardware regression testing all required modes
//               and test cases from the user specification:
//                 Mode 1 (Whole Sequence Matching):
//                   - Exact match
//                   - Length mismatch
//                   - Base mismatch
//                 Mode 2 (Motif Detection):
//                   - Test A: Non-overlapping matches (ACGTACGTACGT, ACG -> 3 @ 0,4,8)
//                   - Test B: Overlapping matches (AAAAA, AA -> 4 @ 0,1,2,3)
//                   - Test C: No matches (ACGT, TT -> 0 @ none)
//                   - Test D: Entire sequence match (ACGT, ACGT -> 1 @ 0)
//                   - Test E: Maximum capacity (128 bases)
// ============================================================================

`timescale 1ns / 1ps

module tb_dna_regression;

    reg        clk;
    reg        reset;
    reg        start;
    reg        mode; // 0 = Sequence Match, 1 = Motif Detection
    reg  [7:0] reference_length;
    reg  [7:0] motif_length;

    reg        ref_we;
    reg  [6:0] ref_addr;
    reg  [1:0] ref_din;

    reg        motif_we;
    reg  [6:0] motif_addr;
    reg  [1:0] motif_din;

    reg  [6:0] match_read_addr;
    wire [7:0] match_read_pos;

    wire       busy;
    wire       done;
    wire [7:0] match_count;
    wire [7:0] current_position;
    wire       match_found;

    dna_motif_detector uut (
        .clk              (clk),
        .reset            (reset),
        .start            (start),
        .mode             (mode),
        .reference_length (reference_length),
        .motif_length     (motif_length),
        .ref_we           (ref_we),
        .ref_addr         (ref_addr),
        .ref_din          (ref_din),
        .motif_we         (motif_we),
        .motif_addr       (motif_addr),
        .motif_din        (motif_din),
        .match_read_addr  (match_read_addr),
        .match_read_pos   (match_read_pos),
        .busy             (busy),
        .done             (done),
        .match_count      (match_count),
        .current_position (current_position),
        .match_found      (match_found)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk; // 100 MHz clock

    function [1:0] encode_base;
        input [7:0] ch;
        begin
            case (ch)
                "A", "a": encode_base = 2'b00;
                "C", "c": encode_base = 2'b01;
                "G", "g": encode_base = 2'b10;
                "T", "t": encode_base = 2'b11;
                default:  encode_base = 2'b00;
            endcase
        end
    endfunction

    task load_reference;
        input [1023:0] seq_str;
        input integer  len;
        integer idx;
        reg [7:0] ch;
        begin
            reference_length = len[7:0];
            for (idx = 0; idx < len; idx = idx + 1) begin
                ch = seq_str[((len - 1 - idx) * 8) +: 8];
                @(posedge clk);
                ref_we   = 1'b1;
                ref_addr = idx[6:0];
                ref_din  = encode_base(ch);
            end
            @(posedge clk);
            ref_we = 1'b0;
        end
    endtask

    task load_motif;
        input [127:0]  seq_str;
        input integer  len;
        integer idx;
        reg [7:0] ch;
        begin
            motif_length = len[7:0];
            for (idx = 0; idx < len; idx = idx + 1) begin
                ch = seq_str[((len - 1 - idx) * 8) +: 8];
                @(posedge clk);
                motif_we   = 1'b1;
                motif_addr = idx[6:0];
                motif_din  = encode_base(ch);
            end
            @(posedge clk);
            motif_we = 1'b0;
        end
    endtask

    task run_accelerator;
        begin
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            while (!done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;
    integer i;
    reg [7:0] p0, p1, p2, p3;

    initial begin
        reset = 1'b1;
        start = 1'b0;
        mode  = 1'b0;
        ref_we = 1'b0;
        motif_we = 1'b0;
        match_read_addr = 7'd0;
        #20;
        @(posedge clk);
        reset = 1'b0;
        #10;

        $display("================================================================");
        $display("   STARTING DNA ACCELERATOR REGRESSION TESTBENCH");
        $display("================================================================");

        // --------------------------------------------------------------------
        // MODE 1: Whole Sequence Matching
        // --------------------------------------------------------------------
        $display("\n--- MODE 1: SEQUENCE MATCHING ---");

        // Case 1: Exact Match
        mode = 1'b0;
        load_reference("ACGTACGT", 8);
        load_motif("ACGTACGT", 8);
        run_accelerator();
        if (match_count == 8'd1) begin
            $display("[PASS] Mode 1 Exact Match: ACGTACGT == ACGTACGT -> MATCH (count=1)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Mode 1 Exact Match: expected count=1, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        // Case 2: Length Mismatch
        load_reference("ACGTACGT", 8);
        load_motif("ACGT", 4);
        run_accelerator();
        if (match_count == 8'd0) begin
            $display("[PASS] Mode 1 Length Mismatch: ACGTACGT != ACGT -> MISMATCH (count=0)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Mode 1 Length Mismatch: expected count=0, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        // Case 3: Base Mismatch
        load_reference("ACGTACGT", 8);
        load_motif("ACGTTCGT", 8);
        run_accelerator();
        if (match_count == 8'd0) begin
            $display("[PASS] Mode 1 Base Mismatch: ACGTACGT != ACGTTCGT -> MISMATCH (count=0)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Mode 1 Base Mismatch: expected count=0, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // MODE 2: Motif Detection
        // --------------------------------------------------------------------
        $display("\n--- MODE 2: MOTIF DETECTION ---");

        // Test A: Multiple Non-overlapping matches
        // Ref: ACGTACGTACGT, Motif: ACG -> Count: 3, Pos: 0, 4, 8
        mode = 1'b1;
        load_reference("ACGTACGTACGT", 12);
        load_motif("ACG", 3);
        run_accelerator();
        if (match_count == 8'd3) begin
            match_read_addr = 0; #1;
            if (match_read_pos == 8'd0) begin
                match_read_addr = 1; #1;
                if (match_read_pos == 8'd4) begin
                    match_read_addr = 2; #1;
                    if (match_read_pos == 8'd8) begin
                        $display("[PASS] Mode 2 Test A: Ref=ACGTACGTACGT, Motif=ACG -> Count=3, Pos=0,4,8");
                        pass_count = pass_count + 1;
                    end else begin
                        $display("[FAIL] Mode 2 Test A Pos[2]: expected 8, got %0d", match_read_pos);
                        fail_count = fail_count + 1;
                    end
                end else begin
                    $display("[FAIL] Mode 2 Test A Pos[1]: expected 4, got %0d", match_read_pos);
                    fail_count = fail_count + 1;
                end
            end else begin
                $display("[FAIL] Mode 2 Test A Pos[0]: expected 0, got %0d", match_read_pos);
                fail_count = fail_count + 1;
            end
        end else begin
            $display("[FAIL] Mode 2 Test A Count: expected 3, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        // Test B: Overlapping matches
        // Ref: AAAAA, Motif: AA -> Count: 4, Pos: 0, 1, 2, 3
        load_reference("AAAAA", 5);
        load_motif("AA", 2);
        run_accelerator();
        if (match_count == 8'd4) begin
            match_read_addr = 0; #1; p0 = match_read_pos;
            match_read_addr = 1; #1; p1 = match_read_pos;
            match_read_addr = 2; #1; p2 = match_read_pos;
            match_read_addr = 3; #1; p3 = match_read_pos;
            if (p0 == 0 && p1 == 1 && p2 == 2 && p3 == 3) begin
                $display("[PASS] Mode 2 Test B (Overlapping): Ref=AAAAA, Motif=AA -> Count=4, Pos=0,1,2,3");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Mode 2 Test B Positions: got %0d,%0d,%0d,%0d", p0, p1, p2, p3);
                fail_count = fail_count + 1;
            end
        end else begin
            $display("[FAIL] Mode 2 Test B Count: expected 4, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        // Test C: No matches
        // Ref: ACGT, Motif: TT -> Count: 0, Pos: none
        load_reference("ACGT", 4);
        load_motif("TT", 2);
        run_accelerator();
        if (match_count == 8'd0) begin
            $display("[PASS] Mode 2 Test C (No Matches): Ref=ACGT, Motif=TT -> Count=0, Pos=none");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Mode 2 Test C Count: expected 0, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        // Test D: Entire sequence matches
        // Ref: ACGT, Motif: ACGT -> Count: 1, Pos: 0
        load_reference("ACGT", 4);
        load_motif("ACGT", 4);
        run_accelerator();
        if (match_count == 8'd1) begin
            match_read_addr = 0; #1;
            if (match_read_pos == 8'd0) begin
                $display("[PASS] Mode 2 Test D (Entire Seq): Ref=ACGT, Motif=ACGT -> Count=1, Pos=0");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Mode 2 Test D Pos: expected 0, got %0d", match_read_pos);
                fail_count = fail_count + 1;
            end
        end else begin
            $display("[FAIL] Mode 2 Test D Count: expected 1, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        // Test E: Maximum capacity (128 bases reference)
        reference_length = 8'd128;
        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk);
            ref_we   = 1'b1;
            ref_addr = i[6:0];
            ref_din  = (i % 4 == 0) ? 2'b00 : (i % 4 == 1) ? 2'b01 : (i % 4 == 2) ? 2'b10 : 2'b11;
        end
        @(posedge clk);
        ref_we = 1'b0;
        load_motif("ACGT", 4);
        run_accelerator();
        // Repeating ACGT 32 times -> 32 matches
        if (match_count == 8'd32) begin
            $display("[PASS] Mode 2 Test E (128 bases capacity): 32 repeating ACGT -> Count=32");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Mode 2 Test E Count: expected 32, got %0d", match_count);
            fail_count = fail_count + 1;
        end

        $display("\n================================================================");
        $display("   REGRESSION SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("================================================================");

        if (fail_count == 0) begin
            $display("ALL HARDWARE ACCELERATOR REGRESSION TESTS PASSED SUCCESSFULLY!\n");
        end else begin
            $display("ERROR: SOME HARDWARE REGRESSION TESTS FAILED!\n");
        end

        $finish;
    end

endmodule
