// ============================================================================
// Module Name:  diag_top
// Project:      PicoRV32 Standalone I2C Hardware Bus Scanner
// Target:       Real Digital Boolean FPGA Board (Spartan-7 XC7S50-CSGA324-1)
// Description:  Diagnostic top-level module preserving the entire PicoRV32
//               system architecture, bootloader ROM, App RAM, UART bridge,
//               LEDs, Seven-Segment Display, and DNA subsystem, while
//               integrating the diagnostic I2C hardware master (diag_i2c_master)
//               at MMIO 0x6000_0000.
//
// Address map:
//   0x0000_0000 - 0x0000_07FF : Boot ROM   (512 x 32-bit = 2 KB) - resident bootloader
//   0x1000_0000 - 0x1000_1FFF : App RAM    (2048 x 32-bit = 8 KB) - loaded over UART
//   0x2000_0000               : UART DATA    (read: RX byte, write: TX byte)
//   0x2000_0004               : UART STATUS  (bit0 = tx_busy, bit1 = rx_valid)
//   0x3000_0000               : LED register (16-bit)
//   0x4000_0000               : DNA Accelerator Subsystem
//   0x5000_0000               : Seven-Segment Display Controller
//   0x6000_0000               : Diagnostic I2C Master (Status / Probe / ClkDiv)
//
// Physical I2C Pins:
//   i2c_scl : PMOD C Pin 1 (Package Pin T4, LVCMOS33, PULLUP)
//   i2c_sda : PMOD C Pin 2 (Package Pin R5, LVCMOS33, PULLUP)
// ============================================================================

`timescale 1ns / 1ps

module diag_top (
    input  wire        clk,        // 100 MHz on-board oscillator, pin F14
    input  wire        btn_rst,    // push-button reset, ACTIVE-HIGH, pin J2
    output wire [15:0] led,
    input  wire        UART_rxd,   // from host PC into the FPGA, pin V12
    output wire        UART_txd,   // from the FPGA out to the host PC, pin U11

    // On-board six-digit seven-segment display
    output wire [3:0]  D0_AN,
    output wire [7:0]  D0_SEG,
    output wire [3:0]  D1_AN,
    output wire [7:0]  D1_SEG,

    // External I2C Pins on PMOD C (J4): Pin 1 = T4, Pin 2 = R5
    inout  wire        i2c_scl,
    inout  wire        i2c_sda
);

    // ------------------------------------------------------------------
    // Reset synchronizer (btn_rst active-high -> resetn active-low)
    // ------------------------------------------------------------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk)
        rst_sync <= {rst_sync[0], btn_rst};

    wire resetn = ~rst_sync[1];
    wire dna_reset = ~resetn;

    // ------------------------------------------------------------------
    // PicoRV32 native memory interface
    // ------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    picorv32 #(
        .ENABLE_COUNTERS (0),
        .ENABLE_MUL      (0),
        .ENABLE_DIV      (0),
        .BARREL_SHIFTER  (0),
        .COMPRESSED_ISA  (0),
        .PROGADDR_RESET  (32'h0000_0000)   // always boots into the boot ROM
    ) cpu (
        .clk       (clk),
        .resetn    (resetn),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .irq       (32'b0)
    );

    // ------------------------------------------------------------------
    // Address decode (top 4 bits select region)
    // ------------------------------------------------------------------
    wire rom_sel  = (mem_addr[31:28] == 4'h0);
    wire app_sel  = (mem_addr[31:28] == 4'h1);
    wire uart_sel = (mem_addr[31:28] == 4'h2);
    wire led_sel  = (mem_addr[31:28] == 4'h3);
    wire dna_sel  = (mem_addr[31:28] == 4'h4);
    wire seg7_sel = (mem_addr[31:28] == 4'h5);
    wire i2c_sel  = (mem_addr[31:28] == 4'h6);

    // ------------------------------------------------------------------
    // Boot ROM: 512 x 32-bit = 2 KB, preloaded with the bootloader
    // ------------------------------------------------------------------
    localparam ROM_WORDS = 512;
    reg [31:0] bootrom [0:ROM_WORDS-1];
    initial $readmemh("bootloader.hex", bootrom);

    // ------------------------------------------------------------------
    // Application RAM: 2048 x 32-bit = 8 KB
    // ------------------------------------------------------------------
    localparam APP_WORDS = 2048;
    reg [31:0] appram [0:APP_WORDS-1];
    integer ii;
    initial for (ii = 0; ii < APP_WORDS; ii = ii + 1) appram[ii] = 32'h0;

    // ------------------------------------------------------------------
    // LED register (0x3000_0000)
    // ------------------------------------------------------------------
    reg [15:0] led_reg = 16'h0000;
    assign led = led_reg;

    // ------------------------------------------------------------------
    // UART peripheral: 115200 baud @ 100 MHz system clock
    // ------------------------------------------------------------------
    localparam integer CLKS_PER_BIT = 868;   // 100_000_000 / 115200

    // ---- Transmit ----
    reg        tx_busy = 1'b0;
    reg [15:0] tx_clkcnt;
    reg [3:0]  tx_bitidx;
    reg [9:0]  tx_shiftreg;      // {stop, data[7:0], start}
    reg        uart_txd_reg = 1'b1;
    assign UART_txd = uart_txd_reg;

    wire tx_start = uart_sel && mem_valid && !mem_ready &&
                    (mem_addr[3:2] == 2'b00) && (|mem_wstrb) && !tx_busy;

    always @(posedge clk) begin
        if (!resetn) begin
            tx_busy      <= 1'b0;
            uart_txd_reg <= 1'b1;
        end else if (tx_start) begin
            tx_shiftreg  <= {1'b1, mem_wdata[7:0], 1'b0};
            tx_bitidx    <= 4'd0;
            tx_clkcnt    <= 16'd0;
            tx_busy      <= 1'b1;
            uart_txd_reg <= 1'b0;               // drive start bit immediately
        end else if (tx_busy) begin
            if (tx_clkcnt == CLKS_PER_BIT - 1) begin
                tx_clkcnt <= 16'd0;
                if (tx_bitidx == 4'd9) begin
                    tx_busy <= 1'b0;
                end else begin
                    tx_bitidx    <= tx_bitidx + 4'd1;
                    tx_shiftreg  <= {1'b1, tx_shiftreg[9:1]};
                    uart_txd_reg <= tx_shiftreg[1];
                end
            end else begin
                tx_clkcnt <= tx_clkcnt + 16'd1;
            end
        end
    end

    // ---- Receive ----
    reg [1:0] rxd_sync = 2'b11;
    always @(posedge clk) rxd_sync <= {rxd_sync[0], UART_rxd};
    wire rxd = rxd_sync[1];

    reg        rx_busy = 1'b0;
    reg        rx_aligned = 1'b0;
    reg [15:0] rx_clkcnt;
    reg [3:0]  rx_bitidx;
    reg [7:0]  rx_shiftreg;
    reg        rx_valid = 1'b0;
    reg [7:0]  rx_data;

    wire rx_read_ack = uart_sel && mem_valid && !mem_ready &&
                       (mem_addr[3:2] == 2'b00) && (mem_wstrb == 4'b0000);

    always @(posedge clk) begin
        if (!resetn) begin
            rx_busy  <= 1'b0;
            rx_valid <= 1'b0;
        end else begin
            if (rx_valid && rx_read_ack)
                rx_valid <= 1'b0;

            if (!rx_busy) begin
                if (!rxd) begin
                    rx_busy    <= 1'b1;
                    rx_aligned <= 1'b0;
                    rx_clkcnt  <= CLKS_PER_BIT / 2;
                    rx_bitidx  <= 4'd0;
                end
            end else begin
                if (rx_clkcnt == CLKS_PER_BIT - 1) begin
                    rx_clkcnt <= 16'd0;
                    if (!rx_aligned) begin
                        rx_aligned <= 1'b1;
                    end else if (rx_bitidx == 4'd8) begin
                        rx_busy  <= 1'b0;
                        rx_data  <= rx_shiftreg;
                        rx_valid <= 1'b1;
                    end else begin
                        rx_shiftreg <= {rxd, rx_shiftreg[7:1]};
                        rx_bitidx   <= rx_bitidx + 4'd1;
                    end
                end else begin
                    rx_clkcnt <= rx_clkcnt + 16'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // DNA Accelerator & MMIO Wrapper (0x4000_0000)
    // ------------------------------------------------------------------
    wire        dna_mem_ready;
    wire [31:0] dna_mem_rdata;

    wire        dna_start;
    wire        dna_op_mode;
    wire [7:0]  dna_ref_len;
    wire [7:0]  dna_motif_len;
    wire        dna_ref_we;
    wire [6:0]  dna_ref_addr;
    wire [1:0]  dna_ref_din;
    wire        dna_motif_we;
    wire [6:0]  dna_motif_addr;
    wire [1:0]  dna_motif_din;
    wire [6:0]  dna_match_read_addr;
    wire [7:0]  dna_match_read_pos;
    wire        dna_busy;
    wire        dna_done;
    wire [7:0]  dna_match_count;
    wire [6:0]  dna_position_index;
    wire [7:0]  dna_current_position;
    wire        dna_match_found;

    dna_motif_mmio dna_mmio_inst (
        .clk              (clk),
        .reset            (dna_reset),
        .mem_valid        (mem_valid && dna_sel),
        .mem_addr         (mem_addr),
        .mem_wdata        (mem_wdata),
        .mem_wstrb        (mem_wstrb),
        .mem_ready        (dna_mem_ready),
        .mem_rdata        (dna_mem_rdata),
        .start            (dna_start),
        .op_mode          (dna_op_mode),
        .reference_length (dna_ref_len),
        .motif_length     (dna_motif_len),
        .ref_we           (dna_ref_we),
        .ref_addr         (dna_ref_addr),
        .ref_din          (dna_ref_din),
        .motif_we         (dna_motif_we),
        .motif_addr       (dna_motif_addr),
        .motif_din        (dna_motif_din),
        .match_read_addr  (dna_match_read_addr),
        .match_read_pos   (dna_match_read_pos),
        .busy             (dna_busy),
        .done             (dna_done),
        .match_count      (dna_match_count),
        .position_index   (dna_position_index)
    );

    dna_motif_detector dna_detector_inst (
        .clk              (clk),
        .reset            (dna_reset),
        .start            (dna_start),
        .mode             (dna_op_mode),
        .reference_length (dna_ref_len),
        .motif_length     (dna_motif_len),
        .ref_we           (dna_ref_we),
        .ref_addr         (dna_ref_addr),
        .ref_din          (dna_ref_din),
        .motif_we         (dna_motif_we),
        .motif_addr       (dna_motif_addr),
        .motif_din        (dna_motif_din),
        .match_read_addr  (dna_match_read_addr),
        .match_read_pos   (dna_match_read_pos),
        .busy             (dna_busy),
        .done             (dna_done),
        .match_count      (dna_match_count),
        .current_position (dna_current_position),
        .match_found      (dna_match_found)
    );

    // ------------------------------------------------------------------
    // On-board Six-Digit Seven-Segment Display Controller (0x5000_0000)
    // ------------------------------------------------------------------
    wire        seg7_mem_ready;
    wire [31:0] seg7_mem_rdata;

    seven_segment_controller #(
        .CLK_FREQ_HZ (100_000_000),
        .REFRESH_HZ  (1_000)
    ) seg7_inst (
        .clk       (clk),
        .reset     (dna_reset),
        .mem_valid (mem_valid && seg7_sel),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_ready (seg7_mem_ready),
        .mem_rdata (seg7_mem_rdata),
        .D0_AN     (D0_AN),
        .D0_SEG    (D0_SEG),
        .D1_AN     (D1_AN),
        .D1_SEG    (D1_SEG)
    );

    // ------------------------------------------------------------------
    // OpenCores I2C Master via Native-to-Wishbone Bridge (0x6000_0000)
    // ------------------------------------------------------------------
    wire        oc_i2c_ready;
    wire [31:0] oc_i2c_rdata;
    wire        scl_drive_low;
    wire        sda_drive_low;
    wire        oc_i2c_irq;

    i2c_wb_bridge oc_i2c_inst (
        .clk           (clk),
        .resetn        (resetn),
        .sel           (mem_valid && i2c_sel),
        .wstrb         (mem_wstrb),
        .addr          (mem_addr[4:2]),
        .wdata         (mem_wdata),
        .rdata         (oc_i2c_rdata),
        .ready         (oc_i2c_ready),
        .scl_i         (i2c_scl),
        .scl_drive_low (scl_drive_low),
        .sda_i         (i2c_sda),
        .sda_drive_low (sda_drive_low),
        .irq           (oc_i2c_irq)
    );

    // True Open-Drain physical pads
    assign i2c_scl = scl_drive_low ? 1'b0 : 1'bz;
    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;

    // ------------------------------------------------------------------
    // Memory-mapped access multiplexing
    // ------------------------------------------------------------------
    reg        soc_mem_ready;
    reg [31:0] soc_mem_rdata;

    assign mem_ready = dna_sel  ? dna_mem_ready :
                       seg7_sel ? seg7_mem_ready :
                       i2c_sel  ? oc_i2c_ready  :
                                  soc_mem_ready;

    assign mem_rdata = dna_sel  ? dna_mem_rdata :
                       seg7_sel ? seg7_mem_rdata :
                       i2c_sel  ? oc_i2c_rdata  :
                                  soc_mem_rdata;

    always @(posedge clk) begin
        soc_mem_ready <= 1'b0;

        if (mem_valid && !mem_ready) begin
            if (rom_sel) begin
                soc_mem_ready <= 1'b1;
                soc_mem_rdata <= bootrom[mem_addr[10:2]];
                if (mem_wstrb[0]) bootrom[mem_addr[10:2]][7:0]   <= mem_wdata[7:0];
                if (mem_wstrb[1]) bootrom[mem_addr[10:2]][15:8]  <= mem_wdata[15:8];
                if (mem_wstrb[2]) bootrom[mem_addr[10:2]][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) bootrom[mem_addr[10:2]][31:24] <= mem_wdata[31:24];
            end
            else if (app_sel) begin
                soc_mem_ready <= 1'b1;
                soc_mem_rdata <= appram[mem_addr[12:2]];
                if (mem_wstrb[0]) appram[mem_addr[12:2]][7:0]   <= mem_wdata[7:0];
                if (mem_wstrb[1]) appram[mem_addr[12:2]][15:8]  <= mem_wdata[15:8];
                if (mem_wstrb[2]) appram[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) appram[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
            end
            else if (uart_sel) begin
                soc_mem_ready <= 1'b1;
                if (mem_addr[3:2] == 2'b00)
                    soc_mem_rdata <= {24'h0, rx_data};          // DATA register
                else
                    soc_mem_rdata <= {30'h0, rx_valid, tx_busy}; // STATUS register
            end
            else if (led_sel) begin
                soc_mem_ready <= 1'b1;
                soc_mem_rdata <= {16'h0000, led_reg};
                if (mem_wstrb[0]) led_reg[7:0]  <= mem_wdata[7:0];
                if (mem_wstrb[1]) led_reg[15:8] <= mem_wdata[15:8];
            end
        end
    end

endmodule
