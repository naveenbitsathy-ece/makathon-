// ============================================================================
// Testbench:    tb_dna_motif_mmio
// Project:      PicoRV32-Based DNA Sequence Analysis and Motif Detection
// Description:  Verification testbench for the MMIO wrapper and DNA accelerator.
//               Emulates PicoRV32 memory-mapped IO bus transactions to configure,
//               load sequences, trigger matching, and read results.
// ============================================================================

`timescale 1ns / 1ps

module tb_dna_motif_mmio;

    // ------------------------------------------------------------------------
    // Clock and Reset Signals
    // ------------------------------------------------------------------------
    reg         clk;
    reg         reset;

    // ------------------------------------------------------------------------
    // PicoRV32 Bus Emulation Signals
    // ------------------------------------------------------------------------
    reg         mem_valid;
    reg  [31:0] mem_addr;
    reg  [31:0] mem_wdata;
    reg  [3:0]  mem_wstrb;
    wire        mem_ready;
    wire [31:0] mem_rdata;

    // ------------------------------------------------------------------------
    // MMIO to Detector Interconnect Signals
    // ------------------------------------------------------------------------
    wire        start;
    wire        op_mode;
    wire [7:0]  reference_length;
    wire [7:0]  motif_length;

    wire        ref_we;
    wire [6:0]  ref_addr;
    wire [1:0]  ref_din;

    wire        motif_we;
    wire [6:0]  motif_addr;
    wire [1:0]  motif_din;

    wire [6:0]  match_read_addr;
    wire [7:0]  match_read_pos;

    wire        busy;
    wire        done;
    wire [7:0]  match_count;

    wire [6:0]  position_index;
    wire [7:0]  current_position;
    wire        match_found;
    wire [7:0]  position_data = match_read_pos;

    // ------------------------------------------------------------------------
    // Address Map Constants
    // ------------------------------------------------------------------------
    localparam [31:0] ADDR_REF_DATA       = 32'h4000_0000;
    localparam [31:0] ADDR_MOTIF_DATA     = 32'h4000_0004;
    localparam [31:0] ADDR_CONFIG         = 32'h4000_0008;
    localparam [31:0] ADDR_CONTROL        = 32'h4000_000C;
    localparam [31:0] ADDR_STATUS         = 32'h4000_0010;
    localparam [31:0] ADDR_MATCH_COUNT    = 32'h4000_0014;
    localparam [31:0] ADDR_POSITION_INDEX = 32'h4000_0018;
    localparam [31:0] ADDR_POSITION_DATA  = 32'h4000_001C;
    localparam [31:0] ADDR_SW_SCORE       = 32'h4000_0020;
    localparam [31:0] ADDR_SW_POS         = 32'h4000_0024;
    localparam [31:0] ADDR_SW_ALN_LEN     = 32'h4000_0028;

    // ------------------------------------------------------------------------
    // Testbench Variables
    // ------------------------------------------------------------------------
    integer     i;
    integer     k;
    reg         test_pass;
    reg         all_tests_passed;
    reg [31:0]  rdata;
    reg [7:0]   pos_readback;
    reg [31:0]  status_val;
    reg [31:0]  sw_score_rdata;
    reg [31:0]  sw_pos_rdata;
    reg [31:0]  sw_len_rdata;
    reg [7:0]   recorded_positions [0:127];

    // ------------------------------------------------------------------------
    // Instantiate MMIO Wrapper (DUT 1)
    // ------------------------------------------------------------------------
    dna_motif_mmio uut_mmio (
        .clk              (clk),
        .reset            (reset),
        .mem_valid        (mem_valid),
        .mem_addr         (mem_addr),
        .mem_wdata        (mem_wdata),
        .mem_wstrb        (mem_wstrb),
        .mem_ready        (mem_ready),
        .mem_rdata        (mem_rdata),
        .start            (start),
        .op_mode          (op_mode),
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
        .position_index   (position_index)
    );

    // ------------------------------------------------------------------------
    // Instantiate DNA Motif Detector (DUT 2)
    // ------------------------------------------------------------------------
    dna_motif_detector uut_detector (
        .clk              (clk),
        .reset            (reset),
        .start            (start),
        .mode             (op_mode),
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
    // PicoRV32 MMIO Helper Tasks
    // ------------------------------------------------------------------------
    task mmio_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            mem_valid = 1'b1;
            mem_addr  = addr;
            mem_wdata = data;
            mem_wstrb = 4'b1111;
            @(posedge clk);
            while (!mem_ready) begin
                @(posedge clk);
            end
            mem_valid = 1'b0;
            mem_wstrb = 4'b0000;
            mem_addr  = 32'd0;
            mem_wdata = 32'd0;
        end
    endtask

    task mmio_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            mem_valid = 1'b1;
            mem_addr  = addr;
            mem_wdata = 32'd0;
            mem_wstrb = 4'b0000;
            @(posedge clk);
            while (!mem_ready) begin
                @(posedge clk);
            end
            data = mem_rdata;
            mem_valid = 1'b0;
            mem_addr  = 32'd0;
        end
    endtask

    // ------------------------------------------------------------------------
    // Function: Pack DNA string segment into 32-bit word (16 bases)
    // Packing: bits [1:0]=base0, [3:2]=base1, ... [31:30]=base15
    // ------------------------------------------------------------------------
    function [31:0] pack_dna_word;
        input [1023:0] seq_str;
        input integer  start_idx;
        input integer  total_len;
        integer sub;
        reg [7:0] ch;
        reg [1:0] b;
        reg [31:0] word;
        begin
            word = 32'd0;
            for (sub = 0; sub < 16; sub = sub + 1) begin
                if (start_idx + sub < total_len) begin
                    ch = seq_str[((total_len - 1 - (start_idx + sub)) * 8) +: 8];
                    case (ch)
                        "A", "a": b = 2'b00;
                        "C", "c": b = 2'b01;
                        "G", "g": b = 2'b10;
                        "T", "t": b = 2'b11;
                        default:  b = 2'b00;
                    endcase
                    word[sub*2 +: 2] = b;
                end
            end
            pack_dna_word = word;
        end
    endfunction

    // ------------------------------------------------------------------------
    // Tasks: Write sequences via MMIO
    // ------------------------------------------------------------------------
    task mmio_load_reference;
        input [1023:0] seq_str;
        input integer  len;
        integer w;
        integer num_words;
        begin
            num_words = (len + 15) / 16;
            for (w = 0; w < num_words; w = w + 1) begin
                mmio_write(ADDR_REF_DATA, pack_dna_word(seq_str, w*16, len));
            end
        end
    endtask

    task mmio_load_motif;
        input [127:0]  motif_str;
        input integer  len;
        integer w;
        integer num_words;
        begin
            num_words = (len + 15) / 16;
            for (w = 0; w < num_words; w = w + 1) begin
                mmio_write(ADDR_MOTIF_DATA, pack_dna_word(motif_str, w*16, len));
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Waveform Dumping
    // ------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_dna_motif_mmio.vcd");
        $dumpvars(0, tb_dna_motif_mmio);
    end

    // ------------------------------------------------------------------------
    // Main Verification Procedure
    // ------------------------------------------------------------------------
    initial begin
        // Initialize signals
        reset            = 1'b1;
        mem_valid        = 1'b0;
        mem_addr         = 32'd0;
        mem_wdata        = 32'd0;
        mem_wstrb        = 4'b0000;
        all_tests_passed = 1'b1;

        // Apply reset for 20 ns
        #20;
        @(posedge clk);
        reset = 1'b0;
        #10;

        // ====================================================================
        // MMIO TEST 1:
        // Reference: ACGTACGT (len = 8)
        // Motif:     ACGT     (len = 4)
        // Expected:  match_count = 2, positions = 0, 4
        // ====================================================================
        $display("MMIO TEST 1");

        // 1. Write reference sequence
        mmio_load_reference("ACGTACGT", 8);

        // 2. Write motif sequence
        mmio_load_motif("ACGT", 4);

        // 3. Write configuration: ref_len = 8, motif_len = 4
        mmio_write(ADDR_CONFIG, (4 << 8) | 8);

        // 4. Write START = 1, OP_MODE = 1 (bit 2)
        mmio_write(ADDR_CONTROL, 32'h0000_0005);

        // 5. Poll STATUS until DONE (bit 1 is DONE)
        status_val = 32'd0;
        while ((status_val & 32'h0000_0002) == 0) begin
            mmio_read(ADDR_STATUS, status_val);
        end

        // 6. Read MATCH_COUNT
        mmio_read(ADDR_MATCH_COUNT, rdata);
        $display("Match count = %0d", rdata[7:0]);

        // 7. Read match positions using POSITION_INDEX and POSITION_DATA
        $write("Positions =");
        for (i = 0; i < rdata[7:0]; i = i + 1) begin
            mmio_write(ADDR_POSITION_INDEX, i);
            mmio_read(ADDR_POSITION_DATA, pos_readback);
            recorded_positions[i] = pos_readback[7:0];
            $write(" %0d", pos_readback[7:0]);
        end
        $write("\n");

        // 8. Verify results
        test_pass = 1'b1;
        if (rdata[7:0] != 8'd2) test_pass = 1'b0;
        if (recorded_positions[0] != 8'd0) test_pass = 1'b0;
        if (recorded_positions[1] != 8'd4) test_pass = 1'b0;

        // Read and verify Smith-Waterman Accelerator registers
        mmio_read(ADDR_SW_SCORE, sw_score_rdata);
        mmio_read(ADDR_SW_POS, sw_pos_rdata);
        mmio_read(ADDR_SW_ALN_LEN, sw_len_rdata);
        $display("Smith-Waterman Result: MaxScore=%0d, MaxPos(j,i)=(%0d,%0d), AlnLen=%0d",
                 sw_score_rdata[15:0], sw_pos_rdata[11:8], sw_pos_rdata[3:0], sw_len_rdata[4:0]);
        if (sw_score_rdata[15:0] != 16'd12) test_pass = 1'b0;

        if (test_pass) begin
            $display("PASS\n");
        end else begin
            $display("FAIL\n");
            all_tests_passed = 1'b0;
        end

        #20;

        // ====================================================================
        // MMIO TEST 2:
        // Reference: AAAAAAAAAA (len = 10)
        // Motif:     AAA        (len = 3)
        // Expected:  match_count = 8, positions = 0 1 2 3 4 5 6 7
        // ====================================================================
        $display("MMIO TEST 2");

        // 1. Write reference sequence
        mmio_load_reference("AAAAAAAAAA", 10);

        // 2. Write motif sequence
        mmio_load_motif("AAA", 3);

        // 3. Write configuration: ref_len = 10, motif_len = 3
        mmio_write(ADDR_CONFIG, (3 << 8) | 10);

        // 4. Write START = 1, OP_MODE = 1 (bit 2)
        mmio_write(ADDR_CONTROL, 32'h0000_0005);

        // 5. Poll STATUS until DONE
        status_val = 32'd0;
        while ((status_val & 32'h0000_0002) == 0) begin
            mmio_read(ADDR_STATUS, status_val);
        end

        // 6. Read MATCH_COUNT
        mmio_read(ADDR_MATCH_COUNT, rdata);
        $display("Match count = %0d", rdata[7:0]);

        // 7. Read match positions
        $write("Positions =");
        for (i = 0; i < rdata[7:0]; i = i + 1) begin
            mmio_write(ADDR_POSITION_INDEX, i);
            mmio_read(ADDR_POSITION_DATA, pos_readback);
            recorded_positions[i] = pos_readback[7:0];
            $write(" %0d", pos_readback[7:0]);
        end
        $write("\n");

        // 8. Verify results
        test_pass = 1'b1;
        if (rdata[7:0] != 8'd8) test_pass = 1'b0;
        for (k = 0; k < 8; k = k + 1) begin
            if (recorded_positions[k] != k[7:0]) test_pass = 1'b0;
        end

        if (test_pass) begin
            $display("PASS\n");
        end else begin
            $display("FAIL\n");
            all_tests_passed = 1'b0;
        end

        #20;

        // ====================================================================
        // MMIO TEST 3:
        // Reference: GGGGACGT (len = 8)
        // Motif:     ACGT     (len = 4)
        // Expected:  match_count = 1, position = 4
        // ====================================================================
        $display("MMIO TEST 3");

        // 1. Write reference sequence
        mmio_load_reference("GGGGACGT", 8);

        // 2. Write motif sequence
        mmio_load_motif("ACGT", 4);

        // 3. Write configuration: ref_len = 8, motif_len = 4
        mmio_write(ADDR_CONFIG, (4 << 8) | 8);

        // 4. Write START = 1, OP_MODE = 1 (bit 2)
        mmio_write(ADDR_CONTROL, 32'h0000_0005);

        // 5. Poll STATUS until DONE
        status_val = 32'd0;
        while ((status_val & 32'h0000_0002) == 0) begin
            mmio_read(ADDR_STATUS, status_val);
        end

        // 6. Read MATCH_COUNT
        mmio_read(ADDR_MATCH_COUNT, rdata);
        $display("Match count = %0d", rdata[7:0]);

        // 7. Read match positions
        $write("Positions =");
        for (i = 0; i < rdata[7:0]; i = i + 1) begin
            mmio_write(ADDR_POSITION_INDEX, i);
            mmio_read(ADDR_POSITION_DATA, pos_readback);
            recorded_positions[i] = pos_readback[7:0];
            $write(" %0d", pos_readback[7:0]);
        end
        $write("\n");

        // 8. Verify results
        test_pass = 1'b1;
        if (rdata[7:0] != 8'd1) test_pass = 1'b0;
        if (recorded_positions[0] != 8'd4) test_pass = 1'b0;

        if (test_pass) begin
            $display("PASS\n");
        end else begin
            $display("FAIL\n");
            all_tests_passed = 1'b0;
        end

        #20;

        // ====================================================================
        // Final Summary
        // ====================================================================
        if (all_tests_passed) begin
            $display("ALL MMIO WRAPPER TESTS PASSED\n");
        end else begin
            $display("SOME MMIO TESTS FAILED!\n");
        end

        $finish;
    end

endmodule
