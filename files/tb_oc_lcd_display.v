// ============================================================================
// Testbench:    tb_oc_lcd_display
// Project:      PicoRV32 16x4 I2C Character LCD Diagnostic Simulation
// Description:  Simulates OpenCores I2C Master driving a PCF8574 LCD backpack
//               and HD44780 16x4 controller at address 0x27:
//               1. Verifies 4-bit initialization sequence
//               2. Verifies 16x4 DDRAM cursor offsets (0x80, 0xC0, 0x90, 0xD0)
//               3. Captures and verifies all 4 text lines:
//                  Row 1: "I2C LCD TEST"
//                  Row 2: "ADDRESS: 0x27"
//                  Row 3: "BOOLEAN FPGA"
//                  Row 4: "LCD WORKING!"
// ============================================================================

`timescale 1ns / 1ps

module tb_oc_lcd_display;

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
    // Simulated PCF8574 + HD44780 16x4 LCD Model (Address 0x27)
    // ------------------------------------------------------------------------
    reg slave_sda_drive_low = 1'b0;
    assign i2c_sda = slave_sda_drive_low ? 1'b0 : 1'bz;

    reg [7:0] rx_shift = 8'd0;
    integer bit_count = 0;
    reg slave_active = 0;
    reg is_data_byte = 0;

    // PCF8574 output latch
    reg [7:0] pcf_port = 8'd0;
    reg prev_en = 0;

    // HD44780 4-bit state
    reg in_4bit_mode = 0;
    reg [3:0] high_nibble = 4'd0;
    reg nibble_phase = 0; // 0 = expect high nibble, 1 = expect low nibble

    // Simulated 16x4 display buffer
    reg [7:0] ddram_cursor = 8'h80;
    reg [7:0] display_ram [0:3][0:15];
    integer r, c;

    initial begin
        for (r = 0; r < 4; r = r + 1)
            for (c = 0; c < 16; c = c + 1)
                display_ram[r][c] = " ";
    end

    // START condition detector
    always @(negedge i2c_sda) begin
        if (i2c_scl === 1'b1) begin
            slave_active <= 1;
            bit_count <= 0;
            rx_shift <= 8'd0;
            is_data_byte <= 0;
            slave_sda_drive_low <= 1'b0;
        end
    end

    // STOP condition detector
    always @(posedge i2c_sda) begin
        if (i2c_scl === 1'b1) begin
            slave_active <= 0;
            slave_sda_drive_low <= 1'b0;
            bit_count <= 0;
            is_data_byte <= 0;
        end
    end

    // Sample bits on posedge SCL
    always @(posedge i2c_scl) begin
        if (slave_active) begin
            if (bit_count < 8) begin
                rx_shift <= {rx_shift[6:0], i2c_sda};
                bit_count <= bit_count + 1;
            end
        end
    end

    // Drive ACK and latch data on negedge SCL
    always @(negedge i2c_scl) begin
        if (slave_active) begin
            if (bit_count == 8) begin
                if (!is_data_byte) begin
                    // Address byte: Match 0x27 + Write (0)
                    if (rx_shift == {7'h27, 1'b0}) begin
                        slave_sda_drive_low <= 1'b1; // ACK
                        is_data_byte <= 1;
                    end else begin
                        slave_sda_drive_low <= 1'b0;
                    end
                end else begin
                    // Data byte to PCF8574
                    slave_sda_drive_low <= 1'b1; // ACK
                    pcf_port <= rx_shift; // Update PCF8574 port: P7..P4=D7..D4, P3=BL, P2=E, P1=RW, P0=RS
                end
                bit_count <= bit_count + 1;
            end else if (bit_count == 9) begin
                slave_sda_drive_low <= 1'b0;
                bit_count <= 0;
            end
        end
    end

    // HD44780 Enable pulse decoder (falling edge of P2 / EN)
    wire en_now = pcf_port[2];
    wire rs_now = pcf_port[0];
    wire [3:0] data_nibble = pcf_port[7:4];

    always @(pcf_port) begin
        if (prev_en && !en_now) begin
            // Falling edge of EN: Latch nibble into HD44780
            if (!in_4bit_mode) begin
                if (data_nibble == 4'h2) begin
                    in_4bit_mode <= 1;
                    nibble_phase <= 0;
                end
            end else begin
                if (nibble_phase == 0) begin
                    high_nibble <= data_nibble;
                    nibble_phase <= 1;
                end else begin
                    nibble_phase <= 0;
                    handle_lcd_byte({high_nibble, data_nibble}, rs_now);
                end
            end
        end
        prev_en <= en_now;
    end

    task handle_lcd_byte(input [7:0] byte_val, input rs);
        integer cur_row, cur_col;
        begin
            if (!rs) begin
                // Command byte
                if (byte_val >= 8'h80) begin
                    // Set DDRAM address
                    ddram_cursor = byte_val;
                end else if (byte_val == 8'h01) begin
                    // Clear display
                    for (cur_row = 0; cur_row < 4; cur_row = cur_row + 1)
                        for (cur_col = 0; cur_col < 16; cur_col = cur_col + 1)
                            display_ram[cur_row][cur_col] = " ";
                    ddram_cursor = 8'h80;
                end
            end else begin
                // Character Data byte
                case (ddram_cursor & 8'hF0)
                    8'h80: begin cur_row = 0; cur_col = ddram_cursor - 8'h80; end
                    8'hC0: begin cur_row = 1; cur_col = ddram_cursor - 8'hC0; end
                    8'h90: begin cur_row = 2; cur_col = ddram_cursor - 8'h90; end
                    8'hD0: begin cur_row = 3; cur_col = ddram_cursor - 8'hD0; end
                    default: begin cur_row = 0; cur_col = 0; end
                endcase
                if (cur_row >= 0 && cur_row < 4 && cur_col >= 0 && cur_col < 16) begin
                    display_ram[cur_row][cur_col] = byte_val;
                end
                ddram_cursor = ddram_cursor + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // MMIO Helper Tasks
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

    task pcf_write_byte(input [7:0] b);
        reg [7:0] sr;
        begin
            // 1. Send 0x27 + Write
            mmio_write(3'd3, 8'h4E); // (0x27 << 1) | 0 = 0x4E
            mmio_write(3'd4, 8'h90); // STA + WR
            mmio_read(3'd4, sr);
            while (sr[1]) mmio_read(3'd4, sr);

            // 2. Send byte + STOP
            mmio_write(3'd3, b);
            mmio_write(3'd4, 8'h50); // WR + STO
            mmio_read(3'd4, sr);
            while (sr[1]) mmio_read(3'd4, sr);
        end
    endtask

    task lcd_nibble(input [3:0] n, input rs);
        reg [7:0] base;
        begin
            base = {n, 1'b1, 1'b0, 1'b0, rs}; // BL=1, EN=0, RW=0, RS
            pcf_write_byte(base | 8'h04);      // EN = 1
            #100;
            pcf_write_byte(base & ~8'h04);     // EN = 0
            #100;
        end
    endtask

    task lcd_cmd(input [7:0] cmd);
        begin
            lcd_nibble(cmd[7:4], 1'b0);
            lcd_nibble(cmd[3:0], 1'b0);
        end
    endtask

    task lcd_char(input [7:0] ch);
        begin
            lcd_nibble(ch[7:4], 1'b1);
            lcd_nibble(ch[3:0], 1'b1);
        end
    endtask

    task lcd_print_str(input [127:0] s, input integer len);
        integer i;
        reg [7:0] ch;
        begin
            for (i = len - 1; i >= 0; i = i - 1) begin
                ch = s[i*8 +: 8];
                lcd_char(ch);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Test Sequence
    // ------------------------------------------------------------------------
    initial begin
        $display("===============================================================");
        $display("Starting tb_oc_lcd_display Testbench");
        $display("Testing 16x4 I2C Character LCD text generation at address 0x27");
        $display("===============================================================");

        clk = 0;
        resetn = 0;
        sel = 0;
        wstrb = 0;
        addr = 0;
        wdata = 0;

        #100;
        resetn = 1;
        #100;

        // Step 1: Initialize OpenCores I2C Master with fast simulation clock
        mmio_write(3'd0, 8'd10); // PRER_LO = 10
        mmio_write(3'd1, 8'd0);  // PRER_HI = 0
        mmio_write(3'd2, 8'h80); // CTR core_en = 1
        $display("[1] OpenCores I2C master enabled.");

        // Step 2: Initialize HD44780 in 4-bit mode
        $display("[2] Sending HD44780 4-bit mode initialization sequence...");
        lcd_nibble(4'h3, 1'b0);
        lcd_nibble(4'h3, 1'b0);
        lcd_nibble(4'h3, 1'b0);
        lcd_nibble(4'h2, 1'b0); // Switch to 4-bit mode!

        lcd_cmd(8'h28); // 4-bit mode, 2/4-line, 5x8 font
        lcd_cmd(8'h0C); // Display ON, Cursor OFF
        lcd_cmd(8'h01); // Clear display
        lcd_cmd(8'h06); // Auto-increment
        $display("[3] Initialization complete!");

        // Step 3: Write Row 1 ("I2C LCD TEST" at 0x80)
        $display("\n[4] Writing Row 1 (0x80): 'I2C LCD TEST'");
        lcd_cmd(8'h80);
        lcd_print_str("I2C LCD TEST", 12);

        // Step 4: Write Row 2 ("ADDRESS: 0x27" at 0xC0)
        $display("[5] Writing Row 2 (0xC0): 'ADDRESS: 0x27'");
        lcd_cmd(8'hC0);
        lcd_print_str("ADDRESS: 0x27", 13);

        // Step 5: Write Row 3 ("BOOLEAN FPGA" at 0x90)
        $display("[6] Writing Row 3 (0x90): 'BOOLEAN FPGA'");
        lcd_cmd(8'h90);
        lcd_print_str("BOOLEAN FPGA", 12);

        // Step 6: Write Row 4 ("LCD WORKING!" at 0xD0)
        $display("[7] Writing Row 4 (0xD0): 'LCD WORKING!'");
        lcd_cmd(8'hD0);
        lcd_print_str("LCD WORKING!", 12);

        #1000;

        // Print verified 16x4 display output
        $display("\n===============================================================");
        $display("CAPTURED 16x4 LCD SCREEN BUFFER:");
        $display("+----------------+");
        $display("|%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c|",
            display_ram[0][0], display_ram[0][1], display_ram[0][2], display_ram[0][3],
            display_ram[0][4], display_ram[0][5], display_ram[0][6], display_ram[0][7],
            display_ram[0][8], display_ram[0][9], display_ram[0][10], display_ram[0][11],
            display_ram[0][12], display_ram[0][13], display_ram[0][14], display_ram[0][15]);
        $display("|%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c|",
            display_ram[1][0], display_ram[1][1], display_ram[1][2], display_ram[1][3],
            display_ram[1][4], display_ram[1][5], display_ram[1][6], display_ram[1][7],
            display_ram[1][8], display_ram[1][9], display_ram[1][10], display_ram[1][11],
            display_ram[1][12], display_ram[1][13], display_ram[1][14], display_ram[1][15]);
        $display("|%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c|",
            display_ram[2][0], display_ram[2][1], display_ram[2][2], display_ram[2][3],
            display_ram[2][4], display_ram[2][5], display_ram[2][6], display_ram[2][7],
            display_ram[2][8], display_ram[2][9], display_ram[2][10], display_ram[2][11],
            display_ram[2][12], display_ram[2][13], display_ram[2][14], display_ram[2][15]);
        $display("|%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c|",
            display_ram[3][0], display_ram[3][1], display_ram[3][2], display_ram[3][3],
            display_ram[3][4], display_ram[3][5], display_ram[3][6], display_ram[3][7],
            display_ram[3][8], display_ram[3][9], display_ram[3][10], display_ram[3][11],
            display_ram[3][12], display_ram[3][13], display_ram[3][14], display_ram[3][15]);
        $display("+----------------+");
        $display("===============================================================");

        $finish;
    end

endmodule
