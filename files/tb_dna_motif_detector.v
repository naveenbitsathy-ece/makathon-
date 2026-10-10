// ============================================================================
// Testbench:    tb_dna_motif_detector
// Project:      PicoRV32-Based DNA Sequence Analysis and Motif Detection
// Description:  Verification testbench for the standalone hardware accelerator.
//               Executes required test cases and checks exact match count and
//               detected match positions.
// ============================================================================

`timescale 1ns / 1ps

module tb_dna_motif_detector;

    // ------------------------------------------------------------------------
    // Clock and Control Signals
    // ------------------------------------------------------------------------
    reg        clk;
    reg        reset;
    reg        start;
    reg        mode;

    // Configuration Inputs
    reg  [7:0] reference_length;
    reg  [7:0] motif_length;

    // Reference Memory Write Port
    reg        ref_we;
    reg  [6:0] ref_addr;
    reg  [1:0] ref_din;

    // Motif Memory Write Port
    reg        motif_we;
    reg  [6:0] motif_addr;
    reg  [1:0] motif_din;

    // Match Position Read Port
    reg  [6:0] match_read_addr;
    wire [7:0] match_read_pos;

    // Status and Results
    wire       busy;
    wire       done;
    wire [7:0] match_count;

    // Diagnostic & Waveform Signals
    wire [7:0] current_position;
    wire       match_found;

    // Testbench Variables
    integer    i;
    integer    k;
    reg        test_pass;
    reg        all_tests_passed;

    // ------------------------------------------------------------------------
    // Instantiate Device Under Test (DUT)
    // ------------------------------------------------------------------------
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

    // ------------------------------------------------------------------------
    // Clock Generation: 100 MHz (Period = 10 ns)
    // ------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ------------------------------------------------------------------------
    // DNA Encoding Helper Function:
    //   A = 2'b00, C = 2'b01, G = 2'b10, T = 2'b11
    // ------------------------------------------------------------------------
    function [1:0] encode_base;
        input [7:0] char;
        begin
            case (char)
                "A", "a": encode_base = 2'b00;
                "C", "c": encode_base = 2'b01;
                "G", "g": encode_base = 2'b10;
                "T", "t": encode_base = 2'b11;
                default:  encode_base = 2'b00;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------------
    // Task: Load Reference Sequence into ref_mem via write port
    // ------------------------------------------------------------------------
    task load_reference;
        input [1023:0] seq_str;
        input integer  len;
        integer idx;
        reg [7:0] char_val;
        begin
            reference_length = len[7:0];
            for (idx = 0; idx < len; idx = idx + 1) begin
                char_val = seq_str[((len - 1 - idx) * 8) +: 8];
                @(posedge clk);
                ref_we   = 1'b1;
                ref_addr = idx[6:0];
                ref_din  = encode_base(char_val);
            end
            @(posedge clk);
            ref_we = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------------
    // Task: Load Motif Sequence into motif_mem via write port
    // ------------------------------------------------------------------------
    task load_motif;
        input [127:0]  motif_str;
        input integer  len;
        integer idx;
        reg [7:0] char_val;
        begin
            motif_length = len[7:0];
            for (idx = 0; idx < len; idx = idx + 1) begin
                char_val = motif_str[((len - 1 - idx) * 8) +: 8];
                @(posedge clk);
                motif_we   = 1'b1;
                motif_addr = idx[6:0];
                motif_din  = encode_base(char_val);
            end
            @(posedge clk);
            motif_we = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------------
    // Task: Trigger Search and Wait for Completion
    // ------------------------------------------------------------------------
    task run_search;
        begin
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            // Wait until hardware accelerator asserts done
            while (!done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------------
    // Waveform Dumping
    // ------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_dna_motif_detector.vcd");
        $dumpvars(0, tb_dna_motif_detector);
    end

    // ------------------------------------------------------------------------
    // Main Verification Sequence
    // ------------------------------------------------------------------------
    initial begin
        // Initialize control signals
        reset            = 1'b1;
        start            = 1'b0;
        mode             = 1'b1;
        reference_length = 8'd0;
        motif_length     = 5'd0;
        ref_we           = 1'b0;
        ref_addr         = 7'd0;
        ref_din          = 2'd0;
        motif_we         = 1'b0;
        motif_addr       = 4'd0;
        motif_din        = 2'd0;
        match_read_addr  = 7'd0;
        all_tests_passed = 1'b1;

        // Apply reset for 20 ns
        #20;
        @(posedge clk);
        reset = 1'b0;
        #10;

        // ====================================================================
        // TEST CASE 1:
        // Reference: ACGTACGT (len = 8)
        // Motif:     ACGT     (len = 4)
        // Expected:  match_count = 2, positions = 0, 4
        // ====================================================================
        $display("TEST 1");
        $display("Reference = ACGTACGT");
        $display("Motif = ACGT");

        load_reference("ACGTACGT", 8);
        load_motif("ACGT", 4);
        run_search();

        $display("Match count = %0d", match_count);
        $write("Positions =");
        for (i = 0; i < match_count; i = i + 1) begin
            match_read_addr = i[6:0];
            #1;
            $write(" %0d", match_read_pos);
        end
        $write("\n");

        test_pass = 1'b1;
        if (match_count != 8'd2) test_pass = 1'b0;
        match_read_addr = 0; #1; if (match_read_pos != 8'd0) test_pass = 1'b0;
        match_read_addr = 1; #1; if (match_read_pos != 8'd4) test_pass = 1'b0;

        if (test_pass) begin
            $display("PASS\n");
        end else begin
            $display("FAIL\n");
            all_tests_passed = 1'b0;
        end

        #20;

        // ====================================================================
        // TEST CASE 2:
        // Reference: AAAAAAAAAA (len = 10)
        // Motif:     AAA        (len = 3)
        // Expected:  match_count = 8, positions = 0, 1, 2, 3, 4, 5, 6, 7
        // ====================================================================
        $display("TEST 2");
        $display("Reference = AAAAAAAAAA");
        $display("Motif = AAA");

        load_reference("AAAAAAAAAA", 10);
        load_motif("AAA", 3);
        run_search();

        $display("Match count = %0d", match_count);
        $write("Positions =");
        for (i = 0; i < match_count; i = i + 1) begin
            match_read_addr = i[6:0];
            #1;
            $write(" %0d", match_read_pos);
        end
        $write("\n");

        test_pass = 1'b1;
        if (match_count != 8'd8) test_pass = 1'b0;
        for (k = 0; k < 8; k = k + 1) begin
            match_read_addr = k[6:0];
            #1;
            if (match_read_pos != k[7:0]) test_pass = 1'b0;
        end

        if (test_pass) begin
            $display("PASS\n");
        end else begin
            $display("FAIL\n");
            all_tests_passed = 1'b0;
        end

        #20;

        // ====================================================================
        // TEST CASE 3:
        // Reference: GGGGACGT (len = 8)
        // Motif:     ACGT     (len = 4)
        // Expected:  match_count = 1, position = 4
        // ====================================================================
        $display("TEST 3");
        $display("Reference = GGGGACGT");
        $display("Motif = ACGT");

        load_reference("GGGGACGT", 8);
        load_motif("ACGT", 4);
        run_search();

        $display("Match count = %0d", match_count);
        $write("Positions =");
        for (i = 0; i < match_count; i = i + 1) begin
            match_read_addr = i[6:0];
            #1;
            $write(" %0d", match_read_pos);
        end
        $write("\n");

        test_pass = 1'b1;
        if (match_count != 8'd1) test_pass = 1'b0;
        match_read_addr = 0; #1; if (match_read_pos != 8'd4) test_pass = 1'b0;

        if (test_pass) begin
            $display("PASS\n");
        end else begin
            $display("FAIL\n");
            all_tests_passed = 1'b0;
        end

        #20;

        // ====================================================================
        // Summary
        // ====================================================================
        if (all_tests_passed) begin
            $display("ALL TESTS PASSED\n");
        end else begin
            $display("SOME TESTS FAILED!\n");
        end

        $finish;
    end

endmodule
