// ============================================================================
// top.v -- PicoRV32 SoC with a resident UART bootloader (Real Digital
//          Boolean board, Xilinx Spartan-7 XC7S50-CSGA324-1)
//
// Address map:
//   0x0000_0000 - 0x0000_07FF : Boot ROM   (512 x 32-bit = 2 KB) -- always
//                                runs first; this is the resident bootloader
//   0x1000_0000 - 0x1000_1FFF : App RAM    (2048 x 32-bit = 8 KB) -- written
//                                at runtime by the bootloader, over UART
//   0x2000_0000               : UART DATA    (read: RX byte, write: TX byte)
//   0x2000_0004               : UART STATUS  (bit0 = tx_busy, bit1 = rx_valid)
//   0x3000_0000               : LED register (16-bit, write-only-ish)
//
// IMPORTANT: unlike the earlier picorv32_blink design, the application is
// NOT baked in via $readmemh. Only the boot ROM is preloaded (with
// bootloader.hex). The application arrives over UART, at runtime, exactly
// like uploading a sketch to an Arduino -- except since App RAM is
// volatile, this happens again after every reset/power cycle (there is no
// flash here to remember the app across power-off).
// ============================================================================

module top (
    input  wire        clk,        // 100 MHz on-board oscillator, pin F14
    input  wire        btn_rst,    // push-button reset, ACTIVE-HIGH
    output wire [15:0] led,
    input  wire        UART_rxd,   // from host PC into the FPGA
    output wire        UART_txd    // from the FPGA out to the host PC
);

    // ------------------------------------------------------------------
    // Reset synchronizer (btn_rst active-high -> resetn active-low)
    // ------------------------------------------------------------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk)
        rst_sync <= {rst_sync[0], btn_rst};

    wire resetn = ~rst_sync[1];

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

    // ------------------------------------------------------------------
    // Boot ROM: 512 x 32-bit = 2 KB, preloaded with the bootloader
    // ------------------------------------------------------------------
    localparam ROM_WORDS = 512;
    reg [31:0] bootrom [0:ROM_WORDS-1];
    initial $readmemh("bootloader.hex", bootrom);

    // ------------------------------------------------------------------
    // Application RAM: 2048 x 32-bit = 8 KB, written by the bootloader
    // at runtime -- NOT preloaded (starts as zero).
    // ------------------------------------------------------------------
    localparam APP_WORDS = 2048;
    reg [31:0] appram [0:APP_WORDS-1];
    integer ii;
    initial for (ii = 0; ii < APP_WORDS; ii = ii + 1) appram[ii] = 32'h0;

    // ------------------------------------------------------------------
    // LED register
    // ------------------------------------------------------------------
    reg [15:0] led_reg = 16'h0000;
    assign led = led_reg;

    // ------------------------------------------------------------------
    // UART peripheral: 115200 baud @ 100 MHz system clock
    // ------------------------------------------------------------------
    localparam integer CLKS_PER_BIT = 868;   // 100_000_000 / 115200, rounded

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
    reg        rx_aligned = 1'b0;  // have we consumed the start-bit half period yet?
    reg [15:0] rx_clkcnt;
    reg [3:0]  rx_bitidx;
    reg [7:0]  rx_shiftreg;
    reg        rx_valid = 1'b0;
    reg [7:0]  rx_data;

    wire rx_read_ack = uart_sel && mem_valid && !mem_ready &&
                       (mem_addr[3:2] == 2'b00) && (mem_wstrb == 4'b0000);

    // Sampling timeline after the falling edge (start bit) at t=0, in bit
    // periods T: the first rollover below lands at t=T/2 (centre of the
    // START bit -- just consumed, not sampled as data). Every rollover
    // after that is a full period apart, landing at t=1.5T, 2.5T, ... i.e.
    // exactly the centre of data bits 0-7, then the centre of the stop bit
    // for bitidx==8, which is when the byte is finalised.
    always @(posedge clk) begin
        if (!resetn) begin
            rx_busy  <= 1'b0;
            rx_valid <= 1'b0;
        end else begin
            if (rx_valid && rx_read_ack)
                rx_valid <= 1'b0;

            if (!rx_busy) begin
                if (!rxd) begin                 // falling edge = start bit
                    rx_busy    <= 1'b1;
                    rx_aligned <= 1'b0;
                    rx_clkcnt  <= CLKS_PER_BIT / 2;
                    rx_bitidx  <= 4'd0;
                end
            end else begin
                if (rx_clkcnt == CLKS_PER_BIT - 1) begin
                    rx_clkcnt <= 16'd0;
                    if (!rx_aligned) begin
                        // just reached the centre of the START bit --
                        // don't sample it as data, just start counting
                        // full bit periods from here.
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
    wire        dna_reset = ~resetn;
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
    // Memory-mapped access (one-wait-state, same pattern as picorv32_blink)
    // ------------------------------------------------------------------
    reg        soc_mem_ready;
    reg [31:0] soc_mem_rdata;

    assign mem_ready = dna_sel ? dna_mem_ready : soc_mem_ready;
    assign mem_rdata = dna_sel ? dna_mem_rdata : soc_mem_rdata;

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
                // actual TX-start / RX-read-ack side effects handled above
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
