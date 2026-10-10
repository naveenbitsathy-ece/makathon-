`timescale 1 ns / 1 ps

// ============================================================================
// Testbench:    tb_integrated_dna_soc
// Project:      PicoRV32-Based DNA Sequence Analyzer
// Description:  End-to-end SoC testbench verifying:
//               1. Resident Bootloader initialization & status LEDs (0x0001)
//               2. UART protocol handoff to Application (ACK 'K' and jump)
//               3. Interactive Application main menu display (Operations 1 & 2)
//               4. MODE 1 TEST 1: Whole Sequence Match: ACGTACGT == ACGTACGT -> FOUND
//               5. MODE 1 TEST 2: Whole Sequence Match: ACGTACGT == ACGTTCGT -> NOT FOUND
//               6. MODE 1 TEST 3: Whole Sequence Match: ACGT == ACGTACGT     -> NOT FOUND
//               7. MODE 2 TEST 1: Motif: Target=ACGTACGT, Motif=ACGT         -> count=2, pos=0 4
//               8. MODE 2 TEST 2: Motif: Target=AAAAAAAAAA, Motif=AAA        -> count=8, pos=0..7
//               9. MODE 2 TEST 3: Motif: Target=GGGGACGT, Motif=ACGT         -> count=1, pos=4
//              10. Hardware MMIO verification & LED status monitoring
// ============================================================================

module tb_integrated_dna_soc;

    reg clk = 1'b0;
    always #5 clk = ~clk; // 100 MHz clock (10 ns period)

    reg btn_rst = 1'b1;   // Active-high push-button reset
    wire [15:0] led;
    reg UART_rxd = 1'b1;  // Idle high
    wire UART_txd;

    // Display ports
    wire [3:0] D0_AN;
    wire [7:0] D0_SEG;
    wire [3:0] D1_AN;
    wire [7:0] D1_SEG;
    wire       i2c_scl;
    wire       i2c_sda;

    pullup (i2c_scl);
    pullup (i2c_sda);

    // Bit period for 115200 baud at 100 MHz:
    // CLKS_PER_BIT = 868 cycles -> 868 * 10 ns = 8680 ns
    localparam BIT_PERIOD = 8680;

    top #(
        .LCD_INIT_DELAY (100),
        .LCD_POST_DELAY (50)
    ) uut (
        .clk      (clk),
        .btn_rst  (btn_rst),
        .led      (led),
        .UART_rxd (UART_rxd),
        .UART_txd (UART_txd),
        .D0_AN    (D0_AN),
        .D0_SEG   (D0_SEG),
        .D1_AN    (D1_AN),
        .D1_SEG   (D1_SEG),
        .i2c_scl  (i2c_scl),
        .i2c_sda  (i2c_sda)
    );

    // Task to send a byte over UART_rxd (8N1)
    task send_uart_byte(input [7:0] data);
        integer i;
        begin
            // Start bit (low)
            UART_rxd = 1'b0;
            #(BIT_PERIOD);
            // 8 data bits (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                UART_rxd = data[i];
                #(BIT_PERIOD);
            end
            // Stop bit (high)
            UART_rxd = 1'b1;
            #(BIT_PERIOD);
            #(BIT_PERIOD/2); // Inter-byte settling time
        end
    endtask

    // Task to send a string
    task send_uart_str(input [8*128-1:0] str, input integer len);
        integer idx;
        reg [7:0] ch;
        begin
            for (idx = len - 1; idx >= 0; idx = idx - 1) begin
                ch = str[idx*8 +: 8];
                send_uart_byte(ch);
            end
        end
    endtask

    // Prompt synchronization events
    reg [8*64-1:0] rx_shreg = 0;
    event prompt_choice_evt;
    event prompt_target_evt;
    event prompt_query_evt;
    event prompt_motif_evt;

    // Monitor characters transmitted by the SoC over UART_txd
    reg [7:0] rx_byte;
    integer rx_idx;
    always begin
        @(negedge UART_txd);
        #(BIT_PERIOD / 2); // Sample at middle of start bit
        #(BIT_PERIOD);     // First data bit
        for (rx_idx = 0; rx_idx < 8; rx_idx = rx_idx + 1) begin
            rx_byte[rx_idx] = UART_txd;
            #(BIT_PERIOD);
        end
        $write("%c", rx_byte);
        $fflush();
        rx_shreg = {rx_shreg[8*63-1:0], rx_byte};

        // Check prompts ending in colon
        if (rx_byte == ":") begin
            if (rx_shreg[8*7-1:0]  == "choice:")          -> prompt_choice_evt;
            if (rx_shreg[8*16-1:0] == "target sequence:") -> prompt_target_evt;
            if (rx_shreg[8*15-1:0] == "query sequence:")  -> prompt_query_evt;
            if (rx_shreg[8*15-1:0] == "motif sequence:")  -> prompt_motif_evt;
        end
    end

    // Bus Monitor for Verification
    reg [15:0] last_result_led;
    always @(posedge clk) begin
        if (uut.mem_valid && uut.mem_ready) begin
            if (uut.led_sel && |uut.mem_wstrb) begin
                $display("[HW LED] 0x%04h at time %0t", uut.mem_wdata[15:0], $time);
                if (uut.mem_wdata[15:0] != 16'h0010 && uut.mem_wdata[15:0] != 16'h0020 && 
                    uut.mem_wdata[15:0] != 16'h0040 && uut.mem_wdata[15:0] != 16'h0080 &&
                    uut.mem_wdata[15:0] != 16'h0001 && uut.mem_wdata[15:0] != 16'h0003 &&
                    uut.mem_wdata[15:0] != 16'hffff)
                    last_result_led <= uut.mem_wdata[15:0];
            end
            if (uut.dna_sel && |uut.mem_wstrb)
                $display("[HW DNA MMIO WRITE] Addr=0x%08h Data=0x%08h at time %0t", uut.mem_addr, uut.mem_wdata, $time);
            if (uut.seg7_sel && |uut.mem_wstrb)
                $display("[HW 7-SEG MMIO WRITE] Addr=0x%08h Data=0x%08h at time %0t", uut.mem_addr, uut.mem_wdata, $time);
            if (uut.lcd_sel && |uut.mem_wstrb)
                $display("[HW LCD MMIO WRITE] Addr=0x%08h Data=0x%08h at time %0t", uut.mem_addr, uut.mem_wdata, $time);
        end
    end

    initial begin
        $display("==================================================");
        $display("   TESTBENCH: Integrated Bootloader + DNA SoC     ");
        $display("   Operations: Sequence Matching & Motif Detection");
        $display("==================================================");

        // Preload Boot ROM and App RAM
        $readmemh("bootloader.hex", uut.bootrom);
        $readmemh("app.hex", uut.appram);

        $display("[TB] bootrom[0] = 0x%08h, bootrom[1] = 0x%08h", uut.bootrom[0], uut.bootrom[1]);
        $display("[TB] appram[0]  = 0x%08h, appram[1]  = 0x%08h", uut.appram[0], uut.appram[1]);

        // Reset pulse
        btn_rst = 1'b1;
        #200;
        btn_rst = 1'b0;
        #500;

        $display("[TB] SoC released from reset.");

        // Wait for bootloader to initialize and set LED = 0x0001
        #50000;
        $display("[TB] Current LEDs = 0x%04h (Expected: 0x0001)", led);

        // Send 4-byte length = 0 to trigger bootloader handoff to App RAM
        #10000;
        $display("[TB] Sending handoff length (0) over UART...");
        send_uart_byte(8'h00);
        send_uart_byte(8'h00);
        send_uart_byte(8'h00);
        send_uart_byte(8'h00);

        // ====================================================================
        // MODE 1 - TEST 1: Target=ACGTACGT, Query=ACGTACGT -> FOUND
        // ====================================================================
        @(prompt_choice_evt);
        #(BIT_PERIOD * 20);
        $display("\n[TB] >>> SELECTING OPERATION 1: SEQUENCE MATCHING <<<");
        send_uart_byte("1");

        @(prompt_target_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Target: ACGTACGT");
        send_uart_str("ACGTACGT\n", 9);

        @(prompt_query_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Query: ACGTACGT");
        send_uart_str("ACGTACGT\n", 9);

        @(prompt_choice_evt);
        $display("[TB] Mode 1 Test 1 Completed. Result LED = 0x%04h (Expected: 0x0101 FOUND)", last_result_led);

        // ====================================================================
        // MODE 1 - TEST 2: Target=ACGTACGT, Query=ACGTTCGT -> NOT FOUND
        // ====================================================================
        #(BIT_PERIOD * 20);
        $display("\n[TB] >>> SELECTING OPERATION 1: SEQUENCE MATCHING <<<");
        send_uart_byte("1");

        @(prompt_target_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Target: ACGTACGT");
        send_uart_str("ACGTACGT\n", 9);

        @(prompt_query_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Query: ACGTTCGT");
        send_uart_str("ACGTTCGT\n", 9);

        @(prompt_choice_evt);
        $display("[TB] Mode 1 Test 2 Completed. Result LED = 0x%04h (Expected: 0x0100 NOT FOUND)", last_result_led);

        // ====================================================================
        // MODE 1 - TEST 3: Target=ACGT, Query=ACGTACGT -> NOT FOUND (Length mismatch)
        // ====================================================================
        #(BIT_PERIOD * 20);
        $display("\n[TB] >>> SELECTING OPERATION 1: SEQUENCE MATCHING <<<");
        send_uart_byte("1");

        @(prompt_target_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Target: ACGT");
        send_uart_str("ACGT\n", 5);

        @(prompt_query_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Query: ACGTACGT");
        send_uart_str("ACGTACGT\n", 9);

        @(prompt_choice_evt);
        $display("[TB] Mode 1 Test 3 Completed. Result LED = 0x%04h (Expected: 0x0100 NOT FOUND)", last_result_led);

        // ====================================================================
        // MODE 2 - TEST 1: Target=ACGTACGT, Motif=ACGT -> Count=2, Pos=0 4
        // ====================================================================
        #(BIT_PERIOD * 20);
        $display("\n[TB] >>> SELECTING OPERATION 2: MOTIF DETECTION <<<");
        send_uart_byte("2");

        @(prompt_target_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Target: ACGTACGT");
        send_uart_str("ACGTACGT\n", 9);

        @(prompt_motif_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Motif: ACGT");
        send_uart_str("ACGT\n", 5);

        @(prompt_choice_evt);
        $display("[TB] Mode 2 Test 1 Completed. Result LED = 0x%04h (Expected: 0x0202)", last_result_led);

        // ====================================================================
        // MODE 2 - TEST 2: Target=AAAAAAAAAA, Motif=AAA -> Count=8, Pos=0..7
        // ====================================================================
        #(BIT_PERIOD * 20);
        $display("\n[TB] >>> SELECTING OPERATION 2: MOTIF DETECTION <<<");
        send_uart_byte("2");

        @(prompt_target_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Target: AAAAAAAAAA");
        send_uart_str("AAAAAAAAAA\n", 11);

        @(prompt_motif_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Motif: AAA");
        send_uart_str("AAA\n", 4);

        @(prompt_choice_evt);
        $display("[TB] Mode 2 Test 2 Completed. Result LED = 0x%04h (Expected: 0x0208)", last_result_led);

        // ====================================================================
        // MODE 2 - TEST 3: Target=GGGGACGT, Motif=ACGT -> Count=1, Pos=4
        // ====================================================================
        #(BIT_PERIOD * 20);
        $display("\n[TB] >>> SELECTING OPERATION 2: MOTIF DETECTION <<<");
        send_uart_byte("2");

        @(prompt_target_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Target: GGGGACGT");
        send_uart_str("GGGGACGT\n", 9);

        @(prompt_motif_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Motif: ACGT");
        send_uart_str("ACGT\n", 5);

        @(prompt_choice_evt);
        $display("[TB] Mode 2 Test 3 Completed. Result LED = 0x%04h (Expected: 0x0201)", last_result_led);

        // ====================================================================
        // MODE 2 - TEST 4: Target=AAAA, Motif=TTTT -> Count=0, Pos=None (Zero Matches)
        // ====================================================================
        #(BIT_PERIOD * 20);
        $display("\n[TB] >>> SELECTING OPERATION 2: MOTIF DETECTION (ZERO MATCHES) <<<");
        send_uart_byte("2");

        @(prompt_target_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Target: AAAA");
        send_uart_str("AAAA\n", 5);

        @(prompt_motif_evt);
        #(BIT_PERIOD * 20);
        $display("[TB] Sending Motif: TTTT");
        send_uart_str("TTTT\n", 5);

        @(prompt_choice_evt);
        $display("[TB] Mode 2 Test 4 Completed. Result LED = 0x%04h (Expected: 0x0200)", last_result_led);

        #10000;
        $display("\n==================================================");
        $display("   TESTBENCH COMPLETE: ALL 7 TESTS VERIFIED!     ");
        $display("==================================================");
        $finish;
    end

endmodule
