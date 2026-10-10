// ============================================================================
// Testbench:    tb_oc_i2c_scanner
// Project:      PicoRV32 Standalone I2C Hardware Bus Scanner (OpenCores Core)
// Description:  Verifies i2c_wb_bridge and OpenCores I2C Master controller:
//               1. Wishbone MMIO registers (PRER, CTR, TXR, CR, SR)
//               2. START condition, address + write transmission, STOP condition
//               3. ACK detection from simulated I2C slaves at 0x27 and 0x3F
//               4. NACK detection for non-existent addresses
//               5. Multi-device scan across standard 7-bit address range 0x08 - 0x77
// ============================================================================

`timescale 1ns / 1ps

module tb_oc_i2c_scanner;

    reg clk;
    reg resetn;

    // MMIO bus
    reg         sel;
    reg  [3:0]  wstrb;
    reg  [2:0]  addr;
    reg  [31:0] wdata;
    wire [31:0] rdata;
    wire        ready;

    // Open-Drain I2C bus wires with pullups
    wire i2c_scl;
    wire i2c_sda;
    pullup p_scl (i2c_scl);
    pullup p_sda (i2c_sda);

    wire scl_drive_low;
    wire sda_drive_low;
    wire irq;

    assign i2c_scl = scl_drive_low ? 1'b0 : 1'bz;
    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;

    // Instantiate i2c_wb_bridge
    i2c_wb_bridge uut (
        .clk           (clk),
        .resetn        (resetn),
        .sel           (sel),
        .wstrb         (wstrb),
        .addr          (addr),
        .wdata         (wdata),
        .rdata         (rdata),
        .ready         (ready),
        .scl_i         (i2c_scl),
        .scl_drive_low (scl_drive_low),
        .sda_i         (i2c_sda),
        .sda_drive_low (sda_drive_low),
        .irq           (irq)
    );

    // 100 MHz clock
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Simulated I2C Slave Model (Responds to 0x27 and 0x3F)
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
                // Match address 0x27 or 0x3F with write bit (0)
                if (rx_shift == {7'h27, 1'b0} || rx_shift == {7'h3F, 1'b0}) begin
                    slave_sda_drive_low <= 1'b1; // ACK
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
    // MMIO Tasks
    // ------------------------------------------------------------------------
    task mmio_write(input [2:0] reg_idx, input [7:0] val);
        begin
            @(posedge clk);
            sel   <= 1'b1;
            wstrb <= 4'b0001;
            addr  <= reg_idx;
            wdata <= {24'd0, val};
            @(posedge clk);
            while (!ready) @(posedge clk);
            sel   <= 1'b0;
            wstrb <= 4'b0000;
            @(posedge clk);
        end
    endtask

    task mmio_read(input [2:0] reg_idx, output [7:0] val);
        begin
            @(posedge clk);
            sel   <= 1'b1;
            wstrb <= 4'b0000;
            addr  <= reg_idx;
            @(posedge clk);
            while (!ready) @(posedge clk);
            val = rdata[7:0];
            sel <= 1'b0;
            @(posedge clk);
        end
    endtask

    task probe_address(input [6:0] dev_addr, output ack_detected);
        reg [7:0] sr;
        begin
            // 1. Write (dev_addr << 1) | 0 to TXR (reg_idx = 3)
            mmio_write(3'd3, {dev_addr, 1'b0});

            // 2. Write STA | WR | STO (0x80 | 0x10 | 0x40 = 0xD0) to CR (reg_idx = 4)
            mmio_write(3'd4, 8'hD0);

            // 3. Poll TIP (Transfer In Progress, bit 1 of SR) until 0
            mmio_read(3'd4, sr);
            while (sr[1]) begin // while TIP is 1
                mmio_read(3'd4, sr);
            end

            // 4. Check RXACK (bit 7 of SR): 0 = ACK received, 1 = NACK received
            ack_detected = (sr[7] == 1'b0);
        end
    endtask

    // ------------------------------------------------------------------------
    // Test Sequence
    // ------------------------------------------------------------------------
    reg ack;
    integer addr_i;
    integer found_count;
    reg test_fault = 0;

    initial begin
        $display("===============================================================");
        $display("Starting tb_oc_i2c_scanner Testbench (OpenCores I2C Master)");
        $display("Testing i2c_wb_bridge with simulated slaves at 0x27 and 0x3F");
        $display("===============================================================");

        clk = 0;
        resetn = 0;
        sel = 0;
        wstrb = 0;
        addr = 0;
        wdata = 0;
        test_fault = 0;

        #100;
        resetn = 1;
        #100;

        // Step 1: Configure Prescaler (PRER) for fast simulation (e.g. PRER = 19 => 20 cycles per quarter)
        mmio_write(3'd0, 8'd19); // PRER_LO
        mmio_write(3'd1, 8'd0);  // PRER_HI

        // Step 2: Enable Core (CTR: bit 7 = 1)
        mmio_write(3'd2, 8'h80); // CTR core_en = 1
        $display("OpenCores I2C core initialized and enabled.");

        // Test 1: Probe non-existent address (0x10) -> Expect NACK (ack = 0)
        $display("\n[TEST 1] Probing non-existent address 0x10...");
        probe_address(7'h10, ack);
        $display("Result: ack=%0d", ack);
        if (ack !== 1'b0) begin
            $display("ERROR: Expected NACK on address 0x10!");
            test_fault = 1;
        end else begin
            $display("PASS: Address 0x10 correctly returned NACK.");
        end

        // Test 2: Probe address 0x27 -> Expect ACK (ack = 1)
        $display("\n[TEST 2] Probing simulated LCD backpack at address 0x27...");
        probe_address(7'h27, ack);
        $display("Result: ack=%0d", ack);
        if (ack !== 1'b1) begin
            $display("ERROR: Expected ACK on address 0x27!");
            test_fault = 1;
        end else begin
            $display("PASS: Address 0x27 correctly acknowledged (ACK detected)!");
        end

        // Test 3: Probe address 0x3F -> Expect ACK (ack = 1)
        $display("\n[TEST 3] Probing alternate LCD backpack at address 0x3F...");
        probe_address(7'h3F, ack);
        $display("Result: ack=%0d", ack);
        if (ack !== 1'b1) begin
            $display("ERROR: Expected ACK on address 0x3F!");
            test_fault = 1;
        end else begin
            $display("PASS: Address 0x3F correctly acknowledged (ACK detected)!");
        end

        // Test 4: Sweep standard 7-bit address range 0x08 - 0x77 (112 addresses)
        $display("\n[TEST 4] Scanning full 7-bit address range 0x08 - 0x77...");
        found_count = 0;
        for (addr_i = 8; addr_i <= 119; addr_i = addr_i + 1) begin
            probe_address(addr_i[6:0], ack);
            if (ack) begin
                $display(">>> ACK detected at address 0x%02h <<<", addr_i[6:0]);
                found_count = found_count + 1;
                if (addr_i !== 7'h27 && addr_i !== 7'h3F) begin
                    $display("ERROR: Unexpected ACK at 0x%02h!", addr_i[6:0]);
                    test_fault = 1;
                end
            end
        end

        $display("Scan complete. Devices found: %0d", found_count);
        if (found_count !== 2) begin
            $display("ERROR: Expected exactly 2 devices, found %0d", found_count);
            test_fault = 1;
        end else begin
            $display("PASS: Exactly 2 devices found (0x27 and 0x3F).");
        end

        $display("\n===============================================================");
        if (test_fault == 0) begin
            $display("ALL OPENCORES I2C TESTS PASSED SUCCESSFULLY!");
        end else begin
            $display("FAIL: Some tests encountered errors.");
        end
        $display("===============================================================");

        $finish;
    end

endmodule
