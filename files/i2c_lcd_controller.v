// ============================================================================
// Module Name:  i2c_lcd_controller
// Project:      PicoRV32-Based DNA Sequence Analyzer
// Description:  Reusable hardware controller for external 16x4 I2C character LCD
//               (HD44780 controller + PCF8574/PCF8574A I2C backpack).
//
// Hardware Features:
//   - 100 kHz I2C master generation from 100 MHz system clock.
//   - Open-drain bidirectional SDA / SCL bus control with pull-up compatibility.
//   - 4-bit HD44780 protocol with automatic Enable (E) strobe generation.
//   - Configurable 7-bit slave address: default 7'h3F (PCF8574A) or 7'h27 (PCF8574).
//   - Automatic startup hardware initialization (Function set, Display on, Clear).
//   - Direct MMIO interface for character streaming and cursor positioning.
//
// Row Line Offsets (Standard HD44780 16x4 / 20x4 mapping):
//   - Row 0: 0x80 + col (0x00 .. 0x0F)
//   - Row 1: 0xC0 + col (0x40 .. 0x4F)
//   - Row 2: 0x90 + col (0x10 .. 0x1F)  [or 0x94 for 20x4]
//   - Row 3: 0xD0 + col (0x50 .. 0x5F)  [or 0xD4 for 20x4]
//
// MMIO Interface (Base = 0x6000_0000):
//   +0x00 : LCD_DATA   (W/R) - [7:0] Character write or raw byte
//   +0x04 : LCD_CMD    (W)   - bit 0: Send raw command in [7:0]
//                              bit 1: Set cursor: [7:4]=row (0..3), [3:0]=col (0..15)
//                              bit 2: Clear screen
//                              bit 3: Re-trigger full initialization
//   +0x08 : LCD_ADDR   (W/R) - [6:0] 7-bit I2C slave address (default: 7'h3F)
//   +0x0C : LCD_STATUS (R)   - bit 0: busy, bit 1: ready (done), bit 2: init_done
// ============================================================================

`timescale 1ns / 1ps

module i2c_lcd_controller #(
    parameter integer CLK_FREQ_HZ        = 100_000_000,
    parameter integer I2C_FREQ_HZ        = 100_000,
    parameter [6:0]   DEFAULT_ADDR       = 7'h3F,
    parameter integer INIT_DELAY_CYCLES  = 500_000,
    parameter integer POST_DELAY_CYCLES  = 200_000
)(
    input  wire        clk,
    input  wire        reset,

    // MMIO Bus Interface
    input  wire        mem_valid,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg         mem_ready,
    output reg  [31:0] mem_rdata,

    // External Physical I2C Pins (Bidirectional Open-Drain)
    inout  wire        i2c_scl,
    inout  wire        i2c_sda
);

    // Register map addresses
    localparam [31:0] ADDR_LCD_DATA   = 32'h6000_0000;
    localparam [31:0] ADDR_LCD_CMD    = 32'h6000_0004;
    localparam [31:0] ADDR_LCD_ADDR   = 32'h6000_0008;
    localparam [31:0] ADDR_LCD_STATUS = 32'h6000_000C;

    // Registers
    reg [6:0] slave_addr;
    reg       init_done;
    reg       busy;

    // Physical I2C signals
    reg scl_out = 1'b1;
    reg sda_out = 1'b1;
    wire sda_in  = i2c_sda;

    // Open-drain buffers
    assign i2c_scl = scl_out ? 1'bz : 1'b0;
    assign i2c_sda = sda_out ? 1'bz : 1'b0;

    // Timing parameters
    localparam integer QUARTER_PERIOD = CLK_FREQ_HZ / (4 * I2C_FREQ_HZ); // 250 cycles @ 100 kHz

    // Low-level I2C Byte Transmitter FSM
    localparam [3:0] I2C_IDLE      = 4'd0;
    localparam [3:0] I2C_START     = 4'd1;
    localparam [3:0] I2C_SEND_ADDR = 4'd2;
    localparam [3:0] I2C_ACK_ADDR  = 4'd3;
    localparam [3:0] I2C_SEND_DATA = 4'd4;
    localparam [3:0] I2C_ACK_DATA  = 4'd5;
    localparam [3:0] I2C_STOP      = 4'd6;
    localparam [3:0] I2C_DONE      = 4'd7;

    reg [3:0]  i2c_state = I2C_IDLE;
    reg [15:0] i2c_timer = 16'd0;
    reg [1:0]  i2c_qstep = 2'd0;
    reg [3:0]  i2c_bit   = 4'd0;
    reg [7:0]  i2c_shreg = 8'd0;
    reg [7:0]  tx_byte   = 8'd0;
    reg        i2c_start_req = 1'b0;
    reg        i2c_busy      = 1'b0;
    reg        i2c_done      = 1'b0;

    always @(posedge clk) begin
        if (reset) begin
            i2c_state     <= I2C_IDLE;
            i2c_timer     <= 16'd0;
            i2c_qstep     <= 2'd0;
            i2c_bit       <= 4'd0;
            i2c_busy      <= 1'b0;
            i2c_done      <= 1'b0;
            scl_out       <= 1'b1;
            sda_out       <= 1'b1;
        end else begin
            i2c_done <= 1'b0;

            case (i2c_state)
                I2C_IDLE: begin
                    scl_out  <= 1'b1;
                    sda_out  <= 1'b1;
                    i2c_busy <= 1'b0;
                    if (i2c_start_req) begin
                        i2c_busy  <= 1'b1;
                        i2c_timer <= 16'd0;
                        i2c_qstep <= 2'd0;
                        i2c_state <= I2C_START;
                    end
                end

                I2C_START: begin
                    if (i2c_timer >= QUARTER_PERIOD - 1) begin
                        i2c_timer <= 16'd0;
                        case (i2c_qstep)
                            2'd0: begin sda_out <= 1'b0; i2c_qstep <= 2'd1; end // START condition: SDA drops while SCL high
                            2'd1: begin scl_out <= 1'b0; i2c_qstep <= 2'd2; end // SCL drops
                            2'd2: begin
                                i2c_shreg <= {slave_addr, 1'b0}; // Address + Write (0)
                                i2c_bit   <= 4'd7;
                                i2c_qstep <= 2'd0;
                                i2c_state <= I2C_SEND_ADDR;
                            end
                        endcase
                    end else begin
                        i2c_timer <= i2c_timer + 16'd1;
                    end
                end

                I2C_SEND_ADDR: begin
                    if (i2c_timer >= QUARTER_PERIOD - 1) begin
                        i2c_timer <= 16'd0;
                        case (i2c_qstep)
                            2'd0: begin sda_out <= i2c_shreg[i2c_bit]; i2c_qstep <= 2'd1; end
                            2'd1: begin scl_out <= 1'b1;               i2c_qstep <= 2'd2; end
                            2'd2: begin                                i2c_qstep <= 2'd3; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                i2c_qstep <= 2'd0;
                                if (i2c_bit == 4'd0)
                                    i2c_state <= I2C_ACK_ADDR;
                                else
                                    i2c_bit <= i2c_bit - 4'd1;
                            end
                        endcase
                    end else begin
                        i2c_timer <= i2c_timer + 16'd1;
                    end
                end

                I2C_ACK_ADDR: begin
                    if (i2c_timer >= QUARTER_PERIOD - 1) begin
                        i2c_timer <= 16'd0;
                        case (i2c_qstep)
                            2'd0: begin sda_out <= 1'b1; i2c_qstep <= 2'd1; end // Release SDA for ACK
                            2'd1: begin scl_out <= 1'b1; i2c_qstep <= 2'd2; end
                            2'd2: begin                  i2c_qstep <= 2'd3; end
                            2'd3: begin
                                scl_out   <= 1'b0;
                                i2c_shreg <= tx_byte;
                                i2c_bit   <= 4'd7;
                                i2c_qstep <= 2'd0;
                                i2c_state <= I2C_SEND_DATA;
                            end
                        endcase
                    end else begin
                        i2c_timer <= i2c_timer + 16'd1;
                    end
                end

                I2C_SEND_DATA: begin
                    if (i2c_timer >= QUARTER_PERIOD - 1) begin
                        i2c_timer <= 16'd0;
                        case (i2c_qstep)
                            2'd0: begin sda_out <= i2c_shreg[i2c_bit]; i2c_qstep <= 2'd1; end
                            2'd1: begin scl_out <= 1'b1;               i2c_qstep <= 2'd2; end
                            2'd2: begin                                i2c_qstep <= 2'd3; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                i2c_qstep <= 2'd0;
                                if (i2c_bit == 4'd0)
                                    i2c_state <= I2C_ACK_DATA;
                                else
                                    i2c_bit <= i2c_bit - 4'd1;
                            end
                        endcase
                    end else begin
                        i2c_timer <= i2c_timer + 16'd1;
                    end
                end

                I2C_ACK_DATA: begin
                    if (i2c_timer >= QUARTER_PERIOD - 1) begin
                        i2c_timer <= 16'd0;
                        case (i2c_qstep)
                            2'd0: begin sda_out <= 1'b1; i2c_qstep <= 2'd1; end
                            2'd1: begin scl_out <= 1'b1; i2c_qstep <= 2'd2; end
                            2'd2: begin                  i2c_qstep <= 2'd3; end
                            2'd3: begin
                                scl_out   <= 1'b0;
                                sda_out   <= 1'b0;
                                i2c_qstep <= 2'd0;
                                i2c_state <= I2C_STOP;
                            end
                        endcase
                    end else begin
                        i2c_timer <= i2c_timer + 16'd1;
                    end
                end

                I2C_STOP: begin
                    if (i2c_timer >= QUARTER_PERIOD - 1) begin
                        i2c_timer <= 16'd0;
                        case (i2c_qstep)
                            2'd0: begin scl_out <= 1'b1; i2c_qstep <= 2'd1; end
                            2'd1: begin sda_out <= 1'b1; i2c_qstep <= 2'd2; end // STOP condition: SDA rises while SCL high
                            2'd2: begin
                                i2c_state <= I2C_DONE;
                            end
                        endcase
                    end else begin
                        i2c_timer <= i2c_timer + 16'd1;
                    end
                end

                I2C_DONE: begin
                    i2c_busy  <= 1'b0;
                    i2c_done  <= 1'b1;
                    i2c_state <= I2C_IDLE;
                end
            endcase
        end
    end

    // High-Level LCD Command Sequencer
    // In 4-bit PCF8574 format:
    // P7..P4: Data nibble
    // P3: Backlight (1 = ON)
    // P2: Enable (E)
    // P1: R/W (0 = write)
    // P0: RS (0 = command, 1 = data)
    localparam [3:0] SEQ_IDLE      = 4'd0;
    localparam [3:0] SEQ_SEND_HIGH = 4'd1;
    localparam [3:0] SEQ_SEND_LOW  = 4'd2;
    localparam [3:0] SEQ_DELAY     = 4'd3;
    localparam [3:0] SEQ_INIT      = 4'd4;

    reg [3:0]  seq_state = SEQ_INIT;
    reg [2:0]  sub_step  = 3'd0;
    reg [7:0]  cur_byte  = 8'd0;
    reg        cur_rs    = 1'b0;
    reg [23:0] delay_cnt = 24'd0;
    reg [3:0]  init_step = 4'd0;

    // Software requests
    reg        req_write = 1'b0;
    reg [7:0]  req_byte  = 8'd0;
    reg        req_rs    = 1'b0;

    // MMIO bus logic
    always @(posedge clk) begin
        if (reset) begin
            mem_ready   <= 1'b0;
            mem_rdata   <= 32'd0;
            slave_addr  <= DEFAULT_ADDR;
            req_write   <= 1'b0;
            req_byte    <= 8'd0;
            req_rs      <= 1'b0;
        end else begin
            mem_ready <= 1'b0;
            req_write <= 1'b0;

            if (mem_valid && !mem_ready) begin
                mem_ready <= 1'b1;
                if (|mem_wstrb) begin
                    case (mem_addr)
                        ADDR_LCD_DATA: begin
                            req_byte  <= mem_wdata[7:0];
                            req_rs    <= 1'b1; // Data write
                            req_write <= 1'b1;
                        end

                        ADDR_LCD_CMD: begin
                            if (mem_wdata[0]) begin
                                // Raw command
                                req_byte  <= mem_wdata[15:8];
                                req_rs    <= 1'b0; // Command write
                                req_write <= 1'b1;
                            end else if (mem_wdata[1]) begin
                                // Set cursor: row = mem_wdata[5:4], col = mem_wdata[3:0]
                                // Row offsets: row 0=0x80, row 1=0xC0, row 2=0x90, row 3=0xD0
                                case (mem_wdata[5:4])
                                    2'd0: req_byte <= 8'h80 + mem_wdata[3:0];
                                    2'd1: req_byte <= 8'hC0 + mem_wdata[3:0];
                                    2'd2: req_byte <= 8'h90 + mem_wdata[3:0];
                                    2'd3: req_byte <= 8'hD0 + mem_wdata[3:0];
                                endcase
                                req_rs    <= 1'b0;
                                req_write <= 1'b1;
                            end else if (mem_wdata[2]) begin
                                // Clear screen command (0x01)
                                req_byte  <= 8'h01;
                                req_rs    <= 1'b0;
                                req_write <= 1'b1;
                            end
                        end

                        ADDR_LCD_ADDR: begin
                            if (mem_wstrb[0]) slave_addr <= mem_wdata[6:0];
                        end

                        default: ;
                    endcase
                end else begin
                    case (mem_addr)
                        ADDR_LCD_DATA:   mem_rdata <= 32'd0;
                        ADDR_LCD_ADDR:   mem_rdata <= {25'd0, slave_addr};
                        ADDR_LCD_STATUS: mem_rdata <= {29'd0, init_done, ~busy, busy};
                        default:         mem_rdata <= 32'd0;
                    endcase
                end
            end
        end
    end

    // High-Level FSM
    always @(posedge clk) begin
        if (reset) begin
            seq_state     <= SEQ_INIT;
            init_step     <= 4'd0;
            init_done     <= 1'b0;
            busy          <= 1'b1;
            sub_step      <= 3'd0;
            cur_byte      <= 8'd0;
            cur_rs        <= 1'b0;
            delay_cnt     <= 24'd0;
            i2c_start_req <= 1'b0;
            tx_byte       <= 8'd0;
        end else begin
            i2c_start_req <= 1'b0;

            case (seq_state)
                // ------------------------------------------------------------
                // Hardware Startup Initialization (HD44780 standard sequence)
                // ------------------------------------------------------------
                SEQ_INIT: begin
                    busy <= 1'b1;
                    case (init_step)
                        4'd0: begin
                            // Initial power-on delay
                            if (delay_cnt >= INIT_DELAY_CYCLES) begin
                                delay_cnt <= 24'd0;
                                init_step <= 4'd1;
                            end else begin
                                delay_cnt <= delay_cnt + 24'd1;
                            end
                        end

                        // Send 0x33, 0x32 (switch to 4-bit mode)
                        4'd1: begin cur_byte <= 8'h33; cur_rs <= 1'b0; seq_state <= SEQ_SEND_HIGH; init_step <= 4'd2; end
                        4'd2: begin cur_byte <= 8'h32; cur_rs <= 1'b0; seq_state <= SEQ_SEND_HIGH; init_step <= 4'd3; end
                        // 0x28: 4-bit, 2/4-line, 5x8 font
                        4'd3: begin cur_byte <= 8'h28; cur_rs <= 1'b0; seq_state <= SEQ_SEND_HIGH; init_step <= 4'd4; end
                        // 0x0C: Display ON, cursor OFF, blink OFF
                        4'd4: begin cur_byte <= 8'h0C; cur_rs <= 1'b0; seq_state <= SEQ_SEND_HIGH; init_step <= 4'd5; end
                        // 0x01: Clear display
                        4'd5: begin cur_byte <= 8'h01; cur_rs <= 1'b0; seq_state <= SEQ_SEND_HIGH; init_step <= 4'd6; end
                        // 0x06: Entry mode: Increment cursor
                        4'd6: begin cur_byte <= 8'h06; cur_rs <= 1'b0; seq_state <= SEQ_SEND_HIGH; init_step <= 4'd7; end

                        4'd7: begin
                            // Post-init settling delay
                            if (delay_cnt >= POST_DELAY_CYCLES) begin
                                delay_cnt <= 24'd0;
                                init_done <= 1'b1;
                                busy      <= 1'b0;
                                seq_state <= SEQ_IDLE;
                            end else begin
                                delay_cnt <= delay_cnt + 24'd1;
                            end
                        end
                    endcase
                end

                // ------------------------------------------------------------
                // Idle state: Ready for user character or command
                // ------------------------------------------------------------
                SEQ_IDLE: begin
                    busy <= 1'b0;
                    if (req_write) begin
                        busy      <= 1'b1;
                        cur_byte  <= req_byte;
                        cur_rs    <= req_rs;
                        sub_step  <= 3'd0;
                        seq_state <= SEQ_SEND_HIGH;
                    end
                end

                // ------------------------------------------------------------
                // Send Upper Nibble with E strobe (P3=Backlight=1, P1=RW=0)
                // ------------------------------------------------------------
                SEQ_SEND_HIGH: begin
                    case (sub_step)
                        // Step 0: Upper nibble with E = 1
                        3'd0: begin
                            if (!i2c_busy) begin
                                tx_byte       <= {cur_byte[7:4], 1'b1, 1'b1, 1'b0, cur_rs}; // D7..D4, BL=1, E=1, RW=0, RS
                                i2c_start_req <= 1'b1;
                                sub_step      <= 3'd1;
                            end
                        end

                        3'd1: begin
                            if (i2c_done) begin
                                sub_step <= 3'd2;
                            end
                        end

                        // Step 2: Upper nibble with E = 0 (latch data on falling edge)
                        3'd2: begin
                            if (!i2c_busy) begin
                                tx_byte       <= {cur_byte[7:4], 1'b1, 1'b0, 1'b0, cur_rs}; // D7..D4, BL=1, E=0, RW=0, RS
                                i2c_start_req <= 1'b1;
                                sub_step      <= 3'd3;
                            end
                        end

                        3'd3: begin
                            if (i2c_done) begin
                                sub_step  <= 3'd0;
                                seq_state <= SEQ_SEND_LOW;
                            end
                        end
                    endcase
                end

                // ------------------------------------------------------------
                // Send Lower Nibble with E strobe
                // ------------------------------------------------------------
                SEQ_SEND_LOW: begin
                    case (sub_step)
                        // Step 0: Lower nibble with E = 1
                        3'd0: begin
                            if (!i2c_busy) begin
                                tx_byte       <= {cur_byte[3:0], 1'b1, 1'b1, 1'b0, cur_rs}; // D3..D0, BL=1, E=1, RW=0, RS
                                i2c_start_req <= 1'b1;
                                sub_step      <= 3'd1;
                            end
                        end

                        3'd1: begin
                            if (i2c_done) begin
                                sub_step <= 3'd2;
                            end
                        end

                        // Step 2: Lower nibble with E = 0
                        3'd2: begin
                            if (!i2c_busy) begin
                                tx_byte       <= {cur_byte[3:0], 1'b1, 1'b0, 1'b0, cur_rs}; // D3..D0, BL=1, E=0, RW=0, RS
                                i2c_start_req <= 1'b1;
                                sub_step      <= 3'd3;
                            end
                        end

                        3'd3: begin
                            if (i2c_done) begin
                                sub_step  <= 3'd0;
                                delay_cnt <= 24'd0;
                                seq_state <= SEQ_DELAY;
                            end
                        end
                    endcase
                end

                // ------------------------------------------------------------
                // Post-command execution delay
                // ------------------------------------------------------------
                SEQ_DELAY: begin
                    // Clear command (0x01) takes ~1.5 ms; normal commands take ~40 us
                    if ((cur_byte == 8'h01 && delay_cnt >= 24'd150_000) ||
                        (cur_byte != 8'h01 && delay_cnt >= 24'd4_000)) begin
                        delay_cnt <= 24'd0;
                        if (!init_done)
                            seq_state <= SEQ_INIT;
                        else
                            seq_state <= SEQ_IDLE;
                    end else begin
                        delay_cnt <= delay_cnt + 24'd1;
                    end
                end

                default: seq_state <= SEQ_IDLE;
            endcase
        end
    end

endmodule
