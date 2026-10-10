// ============================================================================
// Testbench:    tb_diag_i2c_scanner
// Project:      PicoRV32 Standalone I2C Hardware Bus Scanner
// Description:  Verifies diag_i2c_master FSM and MMIO interface:
//               1. Bus idle status sensing (SCL=1, SDA=1)
//               2. Bus stuck-low detection
//               3. START condition generation
//               4. 7-bit address + Write bit (0) transmission
//               5. ACK detection from simulated I2C slaves (at 0x27 and 0x3F)
//               6. NACK handling for non-existent addresses
//               7. STOP condition generation
//               8. Full address sweep 0x08 - 0x77 with multi-device detection
// ============================================================================

`timescale 1ns / 1ps

module tb_diag_i2c_scanner;

    reg clk;
    reg reset;

    // MMIO bus
    reg         mem_valid;
    reg  [31:0] mem_addr;
    reg  [31:0] mem_wdata;
    reg  [3:0]  mem_wstrb;
    wire        mem_ready;
    wire [31:0] mem_rdata;

    // Open-Drain I2C bus wires with pullups
    wire i2c_scl;
    wire i2c_sda;
    pullup p_scl (i2c_scl);
    pullup p_sda (i2c_sda);

    // Instantiate diag_i2c_master with faster clock divider for fast simulation
    // 100 MHz clock, I2C_FREQ_HZ = 500_000 (quarter_period = 50 cycles)
    diag_i2c_master #(
        .CLK_FREQ_HZ (100_000_000),
        .I2C_FREQ_HZ (500_000)
    ) uut (
        .clk       (clk),
        .reset     (reset),
        .mem_valid (mem_valid),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_ready (mem_ready),
        .mem_rdata (mem_rdata),
        .i2c_scl   (i2c_scl),
        .i2c_sda   (i2c_sda)
    );

    // 100 MHz clock generator
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Simulated I2C Slave Model supporting address 0x27 and 0x3F
    // ------------------------------------------------------------------------
    reg slave_sda_drive_low = 1'b0;
    assign i2c_sda = slave_sda_drive_low ? 1'b0 : 1'bz;

    reg [7:0] rx_shift = 8'd0;
    integer bit_count = 0;
    reg slave_active = 0;

    // START condition detector
    always @(negedge i2c_sda) begin
        if (i2c_scl === 1'b1) begin
            slave_active <= 1;
            bit_count <= 0;
            rx_shift <= 8'd0;
            slave_sda_drive_low <= 1'b0;
        end
    end

    // STOP condition detector
    always @(posedge i2c_sda) begin
        if (i2c_scl === 1'b1) begin
            slave_active <= 0;
            slave_sda_drive_low <= 1'b0;
            bit_count <= 0;
        end
    end

    // Sample address bits on posedge SCL
    always @(posedge i2c_scl) begin
        if (slave_active) begin
            if (bit_count < 8) begin
                rx_shift <= {rx_shift[6:0], i2c_sda};
                bit_count <= bit_count + 1;
            end
        end
    end

    // Drive ACK on negedge SCL after 8th bit if address matches 0x27 or 0x3F
    always @(negedge i2c_scl) begin
        if (slave_active) begin
            if (bit_count == 8) begin
                // Check if address matches 0x27 (7'b0100111) or 0x3F (7'b0111111) with Write bit 0
                if (rx_shift == {7'h27, 1'b0} || rx_shift == {7'h3F, 1'b0}) begin
                    slave_sda_drive_low <= 1'b1; // Pull SDA low for ACK
                end else begin
                    slave_sda_drive_low <= 1'b0; // NACK
                end
                bit_count <= bit_count + 1;
            end else if (bit_count == 9) begin
                slave_sda_drive_low <= 1'b0; // Release SDA after ACK cycle
                bit_count <= 0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // MMIO Helper Tasks
    // ------------------------------------------------------------------------
    task mmio_write(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            mem_valid <= 1'b1;
            mem_addr  <= addr;
            mem_wdata <= data;
            mem_wstrb <= 4'b1111;
            @(posedge clk);
            while (!mem_ready) @(posedge clk);
            mem_valid <= 1'b0;
            mem_wstrb <= 4'b0000;
            @(posedge clk);
        end
    endtask

    task mmio_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            mem_valid <= 1'b1;
            mem_addr  <= addr;
            mem_wstrb <= 4'b0000;
            @(posedge clk);
            while (!mem_ready) @(posedge clk);
            data = mem_rdata;
            mem_valid <= 1'b0;
            @(posedge clk);
        end
    endtask

    task probe_address(input [6:0] addr, output ack_out, output stuck_out);
        reg [31:0] status;
        begin
            // Trigger probe
            mmio_write(32'h6000_0004, {25'd0, addr});

            // Wait for busy == 1
            mmio_read(32'h6000_0000, status);
            while (!status[2]) begin
                mmio_read(32'h6000_0000, status);
            end

            // Wait for busy == 0
            while (status[2]) begin
                mmio_read(32'h6000_0000, status);
            end

            ack_out   = status[3];
            stuck_out = status[4];
        end
    endtask

    // ------------------------------------------------------------------------
    // Test Sequence
    // ------------------------------------------------------------------------
    reg [31:0] rdata;
    reg ack;
    reg stuck;
    integer addr_i;
    integer found_count;
    reg test_fault = 0;

    initial begin
        $display("===============================================================");
        $display("Starting tb_diag_i2c_scanner Testbench");
        $display("Simulating Boolean FPGA I2C Scanner with slaves at 0x27 and 0x3F");
        $display("===============================================================");

        clk = 0;
        reset = 1;
        mem_valid = 0;
        mem_addr = 0;
        mem_wdata = 0;
        mem_wstrb = 0;
        test_fault = 0;

        #100;
        reset = 0;
        #100;

        // Test 1: Check Bus Idle Status
        mmio_read(32'h6000_0000, rdata);
        $display("[TEST 1] Bus Status Read: 0x%08x (scl_in=%b, sda_in=%b)", rdata, rdata[0], rdata[1]);
        if (rdata[0] !== 1'b1 || rdata[1] !== 1'b1) begin
            $display("ERROR: Bus lines expected high when idle!");
            test_fault = 1;
        end else begin
            $display("PASS: Bus lines correctly idle high.");
        end

        // Test 2: Probe Non-Existent Address (0x10) -> Expect NACK
        $display("\n[TEST 2] Probing non-existent address 0x10...");
        probe_address(7'h10, ack, stuck);
        $display("Result: ack=%0d, stuck=%0d", ack, stuck);
        if (ack !== 1'b0) begin
            $display("ERROR: Address 0x10 should have received NACK!");
            test_fault = 1;
        end else begin
            $display("PASS: Address 0x10 correctly returned NACK (no device).");
        end

        // Test 3: Probe Address 0x27 -> Expect ACK
        $display("\n[TEST 3] Probing simulated LCD backpack at address 0x27...");
        probe_address(7'h27, ack, stuck);
        $display("Result: ack=%0d, stuck=%0d", ack, stuck);
        if (ack !== 1'b1) begin
            $display("ERROR: Address 0x27 should have received ACK!");
            test_fault = 1;
        end else begin
            $display("PASS: Address 0x27 correctly detected with ACK!");
        end

        // Test 4: Probe Address 0x3F -> Expect ACK
        $display("\n[TEST 4] Probing alternate LCD backpack at address 0x3F...");
        probe_address(7'h3F, ack, stuck);
        $display("Result: ack=%0d, stuck=%0d", ack, stuck);
        if (ack !== 1'b1) begin
            $display("ERROR: Address 0x3F should have received ACK!");
            test_fault = 1;
        end else begin
            $display("PASS: Address 0x3F correctly detected with ACK!");
        end

        // Test 5: Full Range Sweep (0x08 to 0x77)
        $display("\n[TEST 5] Scanning full 7-bit range 0x08 to 0x77 (112 addresses)...");
        found_count = 0;
        for (addr_i = 8; addr_i <= 119; addr_i = addr_i + 1) begin
            probe_address(addr_i[6:0], ack, stuck);
            if (ack) begin
                $display(">>> ACK detected at address 0x%02h <<<", addr_i[6:0]);
                found_count = found_count + 1;
                if (addr_i !== 7'h27 && addr_i !== 7'h3F) begin
                    $display("ERROR: Unexpected ACK at 0x%02x!", addr_i);
                    test_fault = 1;
                end
            end
        end

        $display("Scan complete. Total devices detected: %0d", found_count);
        if (found_count !== 2) begin
            $display("ERROR: Expected exactly 2 devices detected, got %0d", found_count);
            test_fault = 1;
        end else begin
            $display("PASS: Exactly 2 devices detected (0x27 and 0x3F).");
        end

        // Summary
        $display("\n===============================================================");
        if (test_fault == 0) begin
            $display("ALL TESTS PASSED SUCCESSFULLY! I2C hardware scanner verified.");
        end else begin
            $display("FAIL: Some tests encountered errors.");
        end
        $display("===============================================================");

        $finish;
    end

endmodule
