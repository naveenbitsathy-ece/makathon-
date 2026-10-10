// ============================================================================
// Module Name:  seven_segment_controller
// Project:      PicoRV32-Based DNA Sequence Analyzer
// Description:  Reusable multiplexed display controller for the 6-digit
//               seven-segment display on the Real Digital Boolean FPGA board.
//
// Display Organization:
//   - Display 0 (DISP0, Digits 0..3): D0_AN[3:0], D0_SEG[7:0]
//   - Display 1 (DISP1, Digits 4..5): D1_AN[1:0], D1_SEG[7:0]
//   - Digits 6..7 (D1_AN[3:2]) held disabled (1'b1).
//
// Polarity:
//   - Anodes: Active-LOW (0 = digit ON, 1 = digit OFF)
//   - Cathodes: Active-LOW (0 = segment ON, 1 = segment OFF)
//   - Segment map: bit 0 = a, 1 = b, 2 = c, 3 = d, 4 = e, 5 = f, 6 = g, 7 = dp
//
// MMIO Interface (Base = 0x5000_0000):
//   +0x00 : SEVENSEG_VAL0  (W/R) - [15:0]  Nibbles for Digits 0..3 (4 bits each)
//   +0x04 : SEVENSEG_VAL1  (W/R) - [7:0]   Nibbles for Digits 4..5 (4 bits each)
//   +0x08 : SEVENSEG_CTRL  (W/R) - [5:0] blanking mask (1 = blank digit), [11:6] decimal points
//   +0x0C : SEVENSEG_RAW0  (W/R) - [31:0] Direct raw segment overrides for Digits 0..3
// ============================================================================

`timescale 1ns / 1ps

module seven_segment_controller #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer REFRESH_HZ  = 1_000        // ~1 kHz refresh rate (each digit ~6 kHz slot)
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

    // Physical Board Outputs
    output reg  [3:0]  D0_AN,
    output reg  [7:0]  D0_SEG,
    output reg  [3:0]  D1_AN,
    output reg  [7:0]  D1_SEG
);

    // Register storage
    reg [15:0] val0_reg;   // Digits 0..3 (4 bits each: digit0=[3:0], digit1=[7:4], digit2=[11:8], digit3=[15:12])
    reg [7:0]  val1_reg;   // Digits 4..5 (4 bits each: digit4=[3:0], digit5=[7:4])
    reg [5:0]  blank_reg;  // 1 = digit blanked
    reg [5:0]  dp_reg;     // 1 = decimal point illuminated (active-low drive: 0)

    // Address constants
    localparam [31:0] ADDR_VAL0 = 32'h5000_0000;
    localparam [31:0] ADDR_VAL1 = 32'h5000_0004;
    localparam [31:0] ADDR_CTRL = 32'h5000_0008;

    // MMIO handling
    always @(posedge clk) begin
        if (reset) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
            val0_reg  <= 16'h0000;
            val1_reg  <= 8'h00;
            blank_reg <= 6'b000000;
            dp_reg    <= 6'b000000;
        end else begin
            mem_ready <= 1'b0;
            if (mem_valid && !mem_ready) begin
                mem_ready <= 1'b1;
                if (|mem_wstrb) begin
                    case (mem_addr)
                        ADDR_VAL0: begin
                            if (mem_wstrb[0]) val0_reg[7:0]   <= mem_wdata[7:0];
                            if (mem_wstrb[1]) val0_reg[15:8]  <= mem_wdata[15:8];
                        end
                        ADDR_VAL1: begin
                            if (mem_wstrb[0]) val1_reg[7:0]   <= mem_wdata[7:0];
                        end
                        ADDR_CTRL: begin
                            if (mem_wstrb[0]) blank_reg       <= mem_wdata[5:0];
                            if (mem_wstrb[1]) dp_reg          <= mem_wdata[11:6];
                        end
                        default: ;
                    endcase
                end else begin
                    case (mem_addr)
                        ADDR_VAL0: mem_rdata <= {16'd0, val0_reg};
                        ADDR_VAL1: mem_rdata <= {24'd0, val1_reg};
                        ADDR_CTRL: mem_rdata <= {20'd0, dp_reg, blank_reg};
                        default:   mem_rdata <= 32'd0;
                    endcase
                end
            end
        end
    end

    // Multiplexing timer: 6 digit slots
    // 100 MHz / (6 * 1000 Hz) = ~16,666 cycles per digit slot
    localparam integer CYCLES_PER_SLOT = CLK_FREQ_HZ / (6 * REFRESH_HZ);
    reg [15:0] slot_timer = 16'd0;
    reg [2:0]  slot_idx   = 3'd0; // 0..5

    always @(posedge clk) begin
        if (reset) begin
            slot_timer <= 16'd0;
            slot_idx   <= 3'd0;
        end else begin
            if (slot_timer >= CYCLES_PER_SLOT - 1) begin
                slot_timer <= 16'd0;
                if (slot_idx == 3'd5)
                    slot_idx <= 3'd0;
                else
                    slot_idx <= slot_idx + 3'd1;
            end else begin
                slot_timer <= slot_timer + 16'd1;
            end
        end
    end

    // 7-Segment Decoder Function (active-low: 0 = on, 1 = off)
    // bit0=a, bit1=b, bit2=c, bit3=d, bit4=e, bit5=f, bit6=g
    function [6:0] hex2seg;
        input [3:0] hex;
        begin
            case (hex)
                4'h0: hex2seg = 7'b1000000; // 0
                4'h1: hex2seg = 7'b1111001; // 1
                4'h2: hex2seg = 7'b0100100; // 2
                4'h3: hex2seg = 7'b0110000; // 3
                4'h4: hex2seg = 7'b0011001; // 4
                4'h5: hex2seg = 7'b0010010; // 5
                4'h6: hex2seg = 7'b0000010; // 6
                4'h7: hex2seg = 7'b1111000; // 7
                4'h8: hex2seg = 7'b0000000; // 8
                4'h9: hex2seg = 7'b0010000; // 9
                4'hA: hex2seg = 7'b0001000; // A
                4'hB: hex2seg = 7'b0000011; // b
                4'hC: hex2seg = 7'b1000110; // C
                4'hD: hex2seg = 7'b0100001; // d
                4'hE: hex2seg = 7'b0000110; // E
                4'hF: hex2seg = 7'b0001110; // F
                default: hex2seg = 7'b1111111;
            endcase
        end
    endfunction

    // Current active digit data
    reg [3:0] cur_nibble;
    reg       cur_blank;
    reg       cur_dp;

    always @(*) begin
        case (slot_idx)
            3'd0: begin
                cur_nibble = val0_reg[3:0];
                cur_blank  = blank_reg[0];
                cur_dp     = dp_reg[0];
            end
            3'd1: begin
                cur_nibble = val0_reg[7:4];
                cur_blank  = blank_reg[1];
                cur_dp     = dp_reg[1];
            end
            3'd2: begin
                cur_nibble = val0_reg[11:8];
                cur_blank  = blank_reg[2];
                cur_dp     = dp_reg[2];
            end
            3'd3: begin
                cur_nibble = val0_reg[15:12];
                cur_blank  = blank_reg[3];
                cur_dp     = dp_reg[3];
            end
            3'd4: begin
                cur_nibble = val1_reg[3:0];
                cur_blank  = blank_reg[4];
                cur_dp     = dp_reg[4];
            end
            3'd5: begin
                cur_nibble = val1_reg[7:4];
                cur_blank  = blank_reg[5];
                cur_dp     = dp_reg[5];
            end
            default: begin
                cur_nibble = 4'h0;
                cur_blank  = 1'b1;
                cur_dp     = 1'b0;
            end
        endcase
    end

    wire [6:0] decoded_segs = hex2seg(cur_nibble);
    wire [7:0] active_seg_pattern = cur_blank ? 8'hFF : {~cur_dp, decoded_segs};

    // Drive outputs per active slot
    always @(posedge clk) begin
        if (reset) begin
            D0_AN  <= 4'b1111;
            D0_SEG <= 8'hFF;
            D1_AN  <= 4'b1111;
            D1_SEG <= 8'hFF;
        end else begin
            case (slot_idx)
                3'd0: begin
                    D0_AN  <= 4'b1110; // Digit 0 active
                    D0_SEG <= active_seg_pattern;
                    D1_AN  <= 4'b1111;
                    D1_SEG <= 8'hFF;
                end
                3'd1: begin
                    D0_AN  <= 4'b1101; // Digit 1 active
                    D0_SEG <= active_seg_pattern;
                    D1_AN  <= 4'b1111;
                    D1_SEG <= 8'hFF;
                end
                3'd2: begin
                    D0_AN  <= 4'b1011; // Digit 2 active
                    D0_SEG <= active_seg_pattern;
                    D1_AN  <= 4'b1111;
                    D1_SEG <= 8'hFF;
                end
                3'd3: begin
                    D0_AN  <= 4'b0111; // Digit 3 active
                    D0_SEG <= active_seg_pattern;
                    D1_AN  <= 4'b1111;
                    D1_SEG <= 8'hFF;
                end
                3'd4: begin
                    D0_AN  <= 4'b1111;
                    D0_SEG <= 8'hFF;
                    D1_AN  <= 4'b1110; // Digit 4 active
                    D1_SEG <= active_seg_pattern;
                end
                3'd5: begin
                    D0_AN  <= 4'b1111;
                    D0_SEG <= 8'hFF;
                    D1_AN  <= 4'b1101; // Digit 5 active
                    D1_SEG <= active_seg_pattern;
                end
                default: begin
                    D0_AN  <= 4'b1111;
                    D0_SEG <= 8'hFF;
                    D1_AN  <= 4'b1111;
                    D1_SEG <= 8'hFF;
                end
            endcase
        end
    end

endmodule
