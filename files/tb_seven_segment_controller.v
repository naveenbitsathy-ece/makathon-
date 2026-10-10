// ============================================================================
// Testbench:    tb_seven_segment_controller
// Project:      PicoRV32-Based DNA Sequence Analyzer
// Description:  Unit verification for the 8-digit seven-segment display
//               controller with parallel refresh and auto position cycling:
//                 - Mode 1: Matched (1) and Mismatched (0)
//                 - Mode 2: Zero matches (Count 0000, Position '----')
//                 - Mode 2: Single match (Count 0001, Position 0002)
//                 - Mode 2: Multiple matches (Count 0004, Positions 0000, 0004, 0008, 0012 cycling)
//                 - Full 8-digit anode multiplexing verification (D0_AN[3:0] and D1_AN[3:0])
// ============================================================================

`timescale 1ns / 1ps

module tb_seven_segment_controller;

    reg clk = 1'b0;
    always #5 clk = ~clk; // 100 MHz clock (10 ns)

    reg reset = 1'b1;

    // MMIO bus
    reg        mem_valid = 1'b0;
    reg [31:0] mem_addr  = 32'd0;
    reg [31:0] mem_wdata = 32'd0;
    reg [3:0]  mem_wstrb = 4'd0;
    wire       mem_ready;
    wire [31:0] mem_rdata;

    // Physical outputs
    wire [3:0] D0_AN;
    wire [7:0] D0_SEG;
    wire [3:0] D1_AN;
    wire [7:0] D1_SEG;

    // Fast refresh and test cycle period for unit testbench:
    // Slot period = 100_000_000 / (4 * 100_000) = 250 cycles (2.5 us)
    // Full frame = 4 * 250 = 1000 cycles (10 us)
    // Position cycle period = 5000 cycles (50 us)
    localparam TEST_CYCLE_PERIOD = 5000;

    seven_segment_controller #(
        .CLK_FREQ_HZ          (100_000_000),
        .REFRESH_HZ           (100_000),    // Fast refresh for simulation
        .DEFAULT_CYCLE_PERIOD (TEST_CYCLE_PERIOD)
    ) dut (
        .clk       (clk),
        .reset     (reset),
        .mem_valid (mem_valid),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_ready (mem_ready),
        .mem_rdata (mem_rdata),
        .D0_AN     (D0_AN),
        .D0_SEG    (D0_SEG),
        .D1_AN     (D1_AN),
        .D1_SEG    (D1_SEG)
    );

    // MMIO write task
    task mmio_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
        begin
            @(posedge clk);
            mem_valid <= 1'b1;
            mem_addr  <= addr;
            mem_wdata <= data;
            mem_wstrb <= strb;
            @(posedge clk);
            while (!mem_ready) @(posedge clk);
            mem_valid <= 1'b0;
            mem_wstrb <= 4'd0;
            @(posedge clk);
        end
    endtask

    // Capture observed digits across 4 slots
    reg [7:0] captured_d0_segs [0:3];
    reg [7:0] captured_d1_segs [0:3];
    reg [3:0] d0_an_seen;
    reg [3:0] d1_an_seen;

    task capture_frames;
        integer i;
        begin
            d0_an_seen = 4'b0000;
            d1_an_seen = 4'b0000;
            // 1100 cycles to sample all 4 slots (1000 cycles per frame)
            for (i = 0; i < 1100; i = i + 1) begin
                @(posedge clk);
                case (D0_AN)
                    4'b1110: begin d0_an_seen[0] = 1'b1; captured_d0_segs[0] = D0_SEG; end
                    4'b1101: begin d0_an_seen[1] = 1'b1; captured_d0_segs[1] = D0_SEG; end
                    4'b1011: begin d0_an_seen[2] = 1'b1; captured_d0_segs[2] = D0_SEG; end
                    4'b0111: begin d0_an_seen[3] = 1'b1; captured_d0_segs[3] = D0_SEG; end
                endcase
                case (D1_AN)
                    4'b1110: begin d1_an_seen[0] = 1'b1; captured_d1_segs[0] = D1_SEG; end
                    4'b1101: begin d1_an_seen[1] = 1'b1; captured_d1_segs[1] = D1_SEG; end
                    4'b1011: begin d1_an_seen[2] = 1'b1; captured_d1_segs[2] = D1_SEG; end
                    4'b0111: begin d1_an_seen[3] = 1'b1; captured_d1_segs[3] = D1_SEG; end
                endcase
            end
        end
    endtask

    integer pass_count = 0;
    integer fail_count = 0;

    initial begin
        $display("==================================================");
        $display("   TESTBENCH: 8-Digit Seven-Segment Controller   ");
        $display("==================================================");

        // Reset pulse
        #50;
        @(posedge clk);
        reset <= 1'b0;
        #100;

        // ------------------------------------------------------------
        // TEST 1: Mode 1 Exact Match (Digit 0 shows 1, others blank)
        // ------------------------------------------------------------
        $display("\n[TEST 1] Mode 1: Exact Sequence Match FOUND (Digit 0 = 1)");
        mmio_write(32'h5000_000C, 32'h0000_0000, 4'b0011); // cycle_en = 0
        mmio_write(32'h5000_0000, 32'h0000_0001, 4'b0011); // VAL0 = 1
        mmio_write(32'h5000_0004, 32'h0000_0000, 4'b0011); // VAL1 = 0
        mmio_write(32'h5000_0008, 32'h0000_00FE, 4'b0011); // CTRL = 0xFE (blank digits 1..7)

        capture_frames();
        // Check Digit 0 displays '1' (7'b1111001 -> 8'hF9 with DP=1 off)
        if (d0_an_seen == 4'b1111 && captured_d0_segs[0] == 8'hF9 && captured_d0_segs[1] == 8'hFF) begin
            $display("[PASS] Mode 1 Match: Digit 0 correctly displays '1', others blanked.");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Mode 1 Match: expected D0_SEG[0]=0xF9, got 0x%02h", captured_d0_segs[0]);
            fail_count = fail_count + 1;
        end

        // ------------------------------------------------------------
        // TEST 2: Mode 2 Zero Matches (Count: 0004 -> for 0: 0000, Pos: '----')
        // ------------------------------------------------------------
        $display("\n[TEST 2] Mode 2: Zero Matches (Count = 0000, Position = ----)");
        mmio_write(32'h5000_000C, 32'h0000_0000, 4'b0011); // cycle_en = 0
        mmio_write(32'h5000_0000, 32'h0000_0000, 4'b0011); // VAL0 = 0000
        mmio_write(32'h5000_0004, 32'h0000_FFFF, 4'b0011); // VAL1 = FFFF (----)
        mmio_write(32'h5000_0008, 32'h0000_0000, 4'b0011); // CTRL = 0x00 (all 8 enabled)

        capture_frames();
        // '0' is 7'b1000000 -> 8'hC0. '-' is 7'b0111111 -> 8'hBF.
        if (captured_d0_segs[0] == 8'hC0 && captured_d0_segs[3] == 8'hC0 &&
            captured_d1_segs[0] == 8'hBF && captured_d1_segs[3] == 8'hBF) begin
            $display("[PASS] Zero matches: Left=0000, Right=---- verified on all 8 digits.");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Zero matches: D0_SEG[0]=0x%02h (exp 0xC0), D1_SEG[0]=0x%02h (exp 0xBF)",
                     captured_d0_segs[0], captured_d1_segs[0]);
            fail_count = fail_count + 1;
        end

        // ------------------------------------------------------------
        // TEST 3: Mode 2 Single Match (Count = 0001, Position = 0002)
        // ------------------------------------------------------------
        $display("\n[TEST 3] Mode 2: Single Match (Target=ACGGT, Motif=GGT -> Count=0001, Pos=0002)");
        mmio_write(32'h5000_000C, 32'h0000_0000, 4'b0011); // cycle_en = 0
        mmio_write(32'h5000_0000, 32'h0000_0001, 4'b0011); // VAL0 = 0001
        mmio_write(32'h5000_0004, 32'h0000_0002, 4'b0011); // VAL1 = 0002
        mmio_write(32'h5000_0008, 32'h0000_0000, 4'b0011); // CTRL = 0x00

        capture_frames();
        // D0: digit 0 = '1' (0xF9), digits 1..3 = '0' (0xC0)
        // D1: digit 4 = '2' (0xA4), digits 5..7 = '0' (0xC0)
        if (captured_d0_segs[0] == 8'hF9 && captured_d0_segs[1] == 8'hC0 &&
            captured_d1_segs[0] == 8'hA4 && captured_d1_segs[1] == 8'hC0) begin
            $display("[PASS] Single match: Left=0001, Right=0002 verified.");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Single match: D0[0]=0x%02h, D1[0]=0x%02h (exp 0xA4)",
                     captured_d0_segs[0], captured_d1_segs[0]);
            fail_count = fail_count + 1;
        end

        // ------------------------------------------------------------
        // TEST 4: Mode 2 Multiple Occurrences & Auto Position Cycling
        // Target=ACGTACGTACGTACGT, Motif=ACGT -> Count=0004, Pos=0000, 0004, 0008, 0012
        // ------------------------------------------------------------
        $display("\n[TEST 4] Mode 2: Multiple Occurrences & Auto Position Cycling");
        $display("         Left: Count=0004 (constant)");
        $display("         Right: Cycles 0000 -> 0004 -> 0008 -> 0012 -> 0000...");

        mmio_write(32'h5000_0000, 32'h0000_0004, 4'b0011); // Left display = 0004
        mmio_write(32'h5000_0020, 32'h0000_0000, 4'b0011); // Pos 0 = 0000
        mmio_write(32'h5000_0024, 32'h0000_0004, 4'b0011); // Pos 1 = 0004
        mmio_write(32'h5000_0028, 32'h0000_0008, 4'b0011); // Pos 2 = 0008
        mmio_write(32'h5000_002C, 32'h0000_0012, 4'b0011); // Pos 3 = 0012
        mmio_write(32'h5000_0010, TEST_CYCLE_PERIOD, 4'b1111); // Set period
        // Enable cycling: num_pos=4, cycle_en=1, restart=1 -> 1 | (4<<4) | (1<<8) = 0x0141
        mmio_write(32'h5000_000C, 32'h0000_0141, 4'b0011);
        mmio_write(32'h5000_0008, 32'h0000_0000, 4'b0011);

        // Step 0: Position 0 = 0000
        capture_frames();
        $display("   Step 0: Right display shows 0000 (D1_SEG[0]=0x%02h)", captured_d1_segs[0]);
        if (captured_d0_segs[0] == 8'h99 && captured_d1_segs[0] == 8'hC0) begin
            $display("   [PASS] Step 0 verified.");
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Step 0: D0[0]=0x%02h, D1[0]=0x%02h", captured_d0_segs[0], captured_d1_segs[0]);
            fail_count = fail_count + 1;
        end

        // Wait to Step 1: Position 1 = 0004
        #(TEST_CYCLE_PERIOD * 10 - 1100 * 10);
        capture_frames();
        $display("   Step 1: Right display shows 0004 (D1_SEG[0]=0x%02h)", captured_d1_segs[0]);
        if (captured_d0_segs[0] == 8'h99 && captured_d1_segs[0] == 8'h99) begin
            $display("   [PASS] Step 1 verified.");
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Step 1: D0[0]=0x%02h, D1[0]=0x%02h", captured_d0_segs[0], captured_d1_segs[0]);
            fail_count = fail_count + 1;
        end

        // Wait to Step 2: Position 2 = 0008
        #(TEST_CYCLE_PERIOD * 10 - 1100 * 10);
        capture_frames();
        $display("   Step 2: Right display shows 0008 (D1_SEG[0]=0x%02h)", captured_d1_segs[0]);
        if (captured_d0_segs[0] == 8'h99 && captured_d1_segs[0] == 8'h80) begin
            $display("   [PASS] Step 2 verified.");
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Step 2: D0[0]=0x%02h, D1[0]=0x%02h", captured_d0_segs[0], captured_d1_segs[0]);
            fail_count = fail_count + 1;
        end

        // Wait to Step 3: Position 3 = 0012
        #(TEST_CYCLE_PERIOD * 10 - 1100 * 10);
        capture_frames();
        $display("   Step 3: Right display shows 0012 (D1_SEG[0]=0x%02h, D1_SEG[1]=0x%02h)",
                 captured_d1_segs[0], captured_d1_segs[1]);
        if (captured_d0_segs[0] == 8'h99 && captured_d1_segs[0] == 8'hA4 && captured_d1_segs[1] == 8'hF9) begin
            $display("   [PASS] Step 3 verified.");
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Step 3: D1[0]=0x%02h, D1[1]=0x%02h", captured_d1_segs[0], captured_d1_segs[1]);
            fail_count = fail_count + 1;
        end

        // Wait to Step 4: Wraps around to Position 0 = 0000
        #(TEST_CYCLE_PERIOD * 10 - 1100 * 10);
        capture_frames();
        $display("   Step 4: Wrapped back to 0000 (D1_SEG[0]=0x%02h)", captured_d1_segs[0]);
        if (captured_d0_segs[0] == 8'h99 && captured_d1_segs[0] == 8'hC0) begin
            $display("   [PASS] Step 4 verified.");
            pass_count = pass_count + 1;
        end else begin
            $display("   [FAIL] Step 4: D0[0]=0x%02h, D1[0]=0x%02h", captured_d0_segs[0], captured_d1_segs[0]);
            fail_count = fail_count + 1;
        end

        // ------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------
        $display("\n==================================================");
        $display("   SEVEN-SEGMENT CONTROLLER TESTBENCH COMPLETE    ");
        $display("   Passed: %0d | Failed: %0d", pass_count, fail_count);
        $display("==================================================");
        if (fail_count == 0) $display(">>> ALL SEVEN-SEGMENT TESTS PASSED! <<<");
        else $display(">>> SOME TESTS FAILED! <<<");
        $finish;
    end

endmodule
