// ============================================================================
// Module Name:  diag_i2c_master
// Project:      PicoRV32 I2C Diagnostic Bus Scanner
// Target:       Real Digital Boolean FPGA Board (Spartan-7 XC7S50)
// Description:  Robust diagnostic I2C master with:
//               1. True bidirectional open-drain SDA and SCL control
//               2. Conservative bus speed (25 kHz default from 100 MHz clock)
//               3. Real-time bus line level sensing (stuck-low detection)
//               4. Single-address probing with exact ACK/NACK bit capture
//               5. START and STOP condition generation
//
// Register Map (Base = 0x6000_0000):
//   +0x00 : I2C_STATUS (R)
//           bit 0: scl_in_live  - Live logic level of physical SCL pin
//           bit 1: sda_in_live  - Live logic level of physical SDA pin
//           bit 2: busy         - 1 when I2C hardware state machine is running
//           bit 3: ack_detected - 1 if slave ACKed (SDA=0 on 9th clock), 0 if NACK
//           bit 4: bus_stuck    - 1 if SDA or SCL was stuck low prior to START
//   +0x04 : I2C_PROBE  (W)
//           [6:0]: 7-bit slave address to probe (generates START -> ADDR+W -> ACK -> STOP)
//   +0x08 : I2C_CLKDIV (W/R)
//           [15:0]: Clock divider quarter-period cycles (default: 1000 => 25 kHz)
// ============================================================================

`timescale 1ns / 1ps

module diag_i2c_master #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer I2C_FREQ_HZ = 25_000         // 25 kHz conservative troubleshooting speed
)(
    input  wire        clk,
    input  wire        reset,

    // MMIO Interface
    input  wire        mem_valid,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output reg         mem_ready,
    output reg  [31:0] mem_rdata,

    // External Physical I2C Pins (True Open-Drain)
    inout  wire        i2c_scl,
    inout  wire        i2c_sda
);

    // Register Offsets
    localparam [31:0] REG_STATUS = 32'h6000_0000;
    localparam [31:0] REG_PROBE  = 32'h6000_0004;
    localparam [31:0] REG_CLKDIV = 32'h6000_0008;

    // Configurable quarter-period (default 100 MHz / (4 * 25 kHz) = 1000 cycles)
    localparam integer DEFAULT_QUARTER = CLK_FREQ_HZ / (4 * I2C_FREQ_HZ);
    reg [15:0] quarter_period = DEFAULT_QUARTER;

    // Open-Drain Driver Registers:
    // 1'b0 -> Release line to High-Z (external/internal pullup pulls high)
    // 1'b1 -> Pull line to GND (0V)
    reg scl_drive_low = 1'b0;
    reg sda_drive_low = 1'b0;

    assign i2c_scl = scl_drive_low ? 1'b0 : 1'bz;
    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;

    // Synchronize input signals to avoid metastability
    reg [1:0] scl_sync = 2'b11;
    reg [1:0] sda_sync = 2'b11;
    always @(posedge clk) begin
        scl_sync <= {scl_sync[0], i2c_scl};
        sda_sync <= {sda_sync[0], i2c_sda};
    end
    wire scl_in = scl_sync[1];
    wire sda_in = sda_sync[1];

    // FSM States
    localparam [3:0] STATE_IDLE       = 4'd0;
    localparam [3:0] STATE_START      = 4'd1;
    localparam [3:0] STATE_SEND_ADDR  = 4'd2;
    localparam [3:0] STATE_READ_ACK   = 4'd3;
    localparam [3:0] STATE_STOP       = 4'd4;
    localparam [3:0] STATE_DONE       = 4'd5;

    reg [3:0]  state = STATE_IDLE;
    reg [15:0] timer = 16'd0;
    reg [1:0]  qstep = 2'd0;
    reg [3:0]  bit_idx = 4'd7;
    reg [7:0]  tx_byte = 8'd0;

    // Status Flags
    reg busy          = 1'b0;
    reg ack_detected  = 1'b0;
    reg bus_stuck     = 1'b0;
    reg probe_start   = 1'b0;
    reg [6:0] probe_addr = 7'd0;

    // MMIO Read / Write
    always @(posedge clk) begin
        if (reset) begin
            mem_ready      <= 1'b0;
            mem_rdata      <= 32'd0;
            probe_start    <= 1'b0;
            quarter_period <= DEFAULT_QUARTER;
        end else begin
            mem_ready   <= 1'b0;
            probe_start <= 1'b0;

            if (mem_valid && !mem_ready) begin
                mem_ready <= 1'b1;
                if (|mem_wstrb) begin
                    // Write
                    case (mem_addr)
                        REG_PROBE: begin
                            probe_addr  <= mem_wdata[6:0];
                            probe_start <= 1'b1;
                        end
                        REG_CLKDIV: begin
                            if (mem_wdata[15:0] >= 16'd10)
                                quarter_period <= mem_wdata[15:0];
                        end
                        default: ;
                    endcase
                end else begin
                    // Read
                    case (mem_addr)
                        REG_STATUS: begin
                            mem_rdata <= {27'd0, bus_stuck, ack_detected, busy, sda_in, scl_in};
                        end
                        REG_CLKDIV: begin
                            mem_rdata <= {16'd0, quarter_period};
                        end
                        default: mem_rdata <= 32'd0;
                    endcase
                end
            end
        end
    end

    // I2C Execution FSM
    always @(posedge clk) begin
        if (reset) begin
            state          <= STATE_IDLE;
            timer          <= 16'd0;
            qstep          <= 2'd0;
            bit_idx        <= 4'd7;
            busy           <= 1'b0;
            ack_detected   <= 1'b0;
            bus_stuck      <= 1'b0;
            scl_drive_low  <= 1'b0; // High-Z (pulled high)
            sda_drive_low  <= 1'b0; // High-Z (pulled high)
        end else begin
            case (state)
                STATE_IDLE: begin
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    busy          <= 1'b0;

                    if (probe_start) begin
                        busy         <= 1'b1;
                        ack_detected <= 1'b0;
                        timer        <= 16'd0;
                        qstep        <= 2'd0;

                        // Check if bus lines are stuck low before starting
                        if (!scl_in || !sda_in) begin
                            bus_stuck <= 1'b1;
                            state     <= STATE_DONE;
                        end else begin
                            bus_stuck <= 1'b0;
                            tx_byte   <= {probe_addr, 1'b0}; // 7-bit addr + Write bit (0)
                            state     <= STATE_START;
                        end
                    end
                end

                // ------------------------------------------------------------
                // START Condition: SDA falls while SCL remains High
                // ------------------------------------------------------------
                STATE_START: begin
                    if (timer >= quarter_period - 1) begin
                        timer <= 16'd0;
                        case (qstep)
                            2'd0: begin sda_drive_low <= 1'b1; qstep <= 2'd1; end // SDA drops low (START)
                            2'd1: begin qstep <= 2'd2; end
                            2'd2: begin scl_drive_low <= 1'b1; qstep <= 2'd3; end // SCL drops low
                            2'd3: begin
                                bit_idx <= 4'd7;
                                qstep   <= 2'd0;
                                state   <= STATE_SEND_ADDR;
                            end
                        endcase
                    end else begin
                        timer <= timer + 16'd1;
                    end
                end

                // ------------------------------------------------------------
                // Transmit 8 Bits (7-bit address + Write bit 0)
                // ------------------------------------------------------------
                STATE_SEND_ADDR: begin
                    if (timer >= quarter_period - 1) begin
                        timer <= 16'd0;
                        case (qstep)
                            2'd0: begin
                                // Setup data bit while SCL is low
                                sda_drive_low <= tx_byte[bit_idx] ? 1'b0 : 1'b1;
                                qstep         <= 2'd1;
                            end
                            2'd1: begin
                                // Raise SCL (clock high)
                                scl_drive_low <= 1'b0;
                                qstep         <= 2'd2;
                            end
                            2'd2: begin
                                qstep <= 2'd3;
                            end
                            2'd3: begin
                                // Lower SCL
                                scl_drive_low <= 1'b1;
                                qstep         <= 2'd0;
                                if (bit_idx == 4'd0) begin
                                    state <= STATE_READ_ACK;
                                end else begin
                                    bit_idx <= bit_idx - 4'd1;
                                end
                            end
                        endcase
                    end else begin
                        timer <= timer + 16'd1;
                    end
                end

                // ------------------------------------------------------------
                // 9th Clock: Sample Slave ACK / NACK
                // ------------------------------------------------------------
                STATE_READ_ACK: begin
                    if (timer >= quarter_period - 1) begin
                        timer <= 16'd0;
                        case (qstep)
                            2'd0: begin
                                // Release SDA so slave can pull it down
                                sda_drive_low <= 1'b0;
                                qstep         <= 2'd1;
                            end
                            2'd1: begin
                                // Raise SCL to sample ACK
                                scl_drive_low <= 1'b0;
                                qstep         <= 2'd2;
                            end
                            2'd2: begin
                                // Sample ACK: 0 = ACK, 1 = NACK
                                ack_detected  <= (sda_in == 1'b0);
                                qstep         <= 2'd3;
                            end
                            2'd3: begin
                                // Lower SCL
                                scl_drive_low <= 1'b1;
                                qstep         <= 2'd0;
                                state         <= STATE_STOP;
                            end
                        endcase
                    end else begin
                        timer <= timer + 16'd1;
                    end
                end

                // ------------------------------------------------------------
                // STOP Condition: SCL rises while SDA is low, then SDA rises
                // ------------------------------------------------------------
                STATE_STOP: begin
                    if (timer >= quarter_period - 1) begin
                        timer <= 16'd0;
                        case (qstep)
                            2'd0: begin
                                sda_drive_low <= 1'b1; // Ensure SDA is low
                                qstep         <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0; // Release SCL high
                                qstep         <= 2'd2;
                            end
                            2'd2: begin
                                qstep <= 2'd3;
                            end
                            2'd3: begin
                                sda_drive_low <= 1'b0; // Release SDA high (STOP)
                                qstep         <= 2'd0;
                                state         <= STATE_DONE;
                            end
                        endcase
                    end else begin
                        timer <= timer + 16'd1;
                    end
                end

                // ------------------------------------------------------------
                // Completion / Settling State
                // ------------------------------------------------------------
                STATE_DONE: begin
                    if (timer >= quarter_period - 1) begin
                        busy  <= 1'b0;
                        state <= STATE_IDLE;
                    end else begin
                        timer <= timer + 16'd1;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
