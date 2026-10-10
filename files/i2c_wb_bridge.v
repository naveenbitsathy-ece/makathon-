`timescale 1ns/1ps
// VitalSoC native-bus to OpenCores I2C Wishbone bridge.
//
// SoC map (word-aligned 32-bit registers at I2C_BASE = 0x6000_0000):
//   addr[2:0] = 0 : PRER[7:0]   (offset 0x00)
//   addr[2:0] = 1 : PRER[15:8]  (offset 0x04)
//   addr[2:0] = 2 : CTR         (offset 0x08)
//   addr[2:0] = 3 : TXR on write / RXR on read (offset 0x0C)
//   addr[2:0] = 4 : CR on write / SR on read   (offset 0x10)
//   addr[2:0] = 5..7 : unmapped; reads return 0xDEADBEEF, writes ignored.
//
// This wrapper expects the standard OpenCores i2c_master_top RTL and its
// dependencies to be included in the Vivado project. It intentionally does
// not reimplement the I2C bit-level state machine; OpenCores handles START,
// repeated START, STOP, ACK/NACK, clock stretching, and transfer status.
//
// Native peripheral handshake matches the SoC's sel/ready slave convention.
// addr is the word register index mem_addr[4:2], not a byte address.
// wstrb[0] qualifies the 8-bit OpenCores register write. Bits [31:8] are zero
// on valid register reads, as required by the VitalSoC register specification.
//
// OpenCores pad output-enable signals are active-low. Its pad output values are
// always zero; when padoen_o == 0 the line is pulled low, otherwise released.
// External pull-up resistors are required on SCL and SDA.
module i2c_wb_bridge (
    input              clk,
    input              resetn,

    input              sel,
    input      [3:0]   wstrb,
    input      [2:0]   addr,
    input      [31:0]  wdata,
    output reg [31:0]  rdata,
    output reg         ready,

    input              scl_i,
    output wire        scl_drive_low,
    input              sda_i,
    output wire        sda_drive_low,

    output wire        irq
);

    reg        bridge_busy;
    reg [2:0]  req_addr;
    reg        req_we;
    reg        req_is_write;
    reg [7:0]  req_wdata;
    reg        unmapped_req;

    reg        wb_cyc;
    reg        wb_stb;
    wire       wb_ack;
    wire [7:0] wb_rdata;
    wire       wb_irq;

    wire       scl_pad_o;
    wire       scl_padoen_o;
    wire       sda_pad_o;
    wire       sda_padoen_o;

    // OpenCores pad outputs are constant-low data with active-low output enable.
    assign scl_drive_low = ~scl_padoen_o;
    assign sda_drive_low = ~sda_padoen_o;
    assign irq = wb_irq;

    // One outstanding native-bus request at a time. Keep Wishbone CYC/STB high
    // until the OpenCores slave acknowledges the request.
    wire request_start = sel && !ready && !bridge_busy;

    always @(posedge clk) begin
        if (!resetn) begin
            bridge_busy <= 1'b0;
            req_addr    <= 3'd0;
            req_we      <= 1'b0;
            req_is_write <= 1'b0;
            req_wdata   <= 8'd0;
            unmapped_req <= 1'b0;
            wb_cyc      <= 1'b0;
            wb_stb      <= 1'b0;
            ready       <= 1'b0;
            rdata       <= 32'd0;
        end else begin
            ready <= 1'b0;

            if (request_start) begin
                req_addr <= addr;
                req_is_write <= |wstrb;
                req_we <= (|wstrb) && wstrb[0];
                req_wdata <= wdata[7:0];
                if (addr > 3'd4) begin
                    // Reserved offsets are acknowledged locally.
                    unmapped_req <= 1'b1;
                    bridge_busy <= 1'b1;
                end else if ((|wstrb) && !wstrb[0]) begin
                    // These registers are byte-wide; a write without byte lane 0
                    // is ignored but still completes as a bus access.
                    unmapped_req <= 1'b1;
                    bridge_busy <= 1'b1;
                end else begin
                    unmapped_req <= 1'b0;
                    bridge_busy <= 1'b1;
                    wb_cyc <= 1'b1;
                    wb_stb <= 1'b1;
                end
            end

            if (bridge_busy && unmapped_req) begin
                rdata <= req_is_write ? 32'd0 : 32'hDEAD_BEEF;
                ready <= 1'b1;
                bridge_busy <= 1'b0;
                unmapped_req <= 1'b0;
            end else if (bridge_busy && wb_ack) begin
                rdata <= req_we ? 32'd0 : {24'd0, wb_rdata};
                ready <= 1'b1;
                bridge_busy <= 1'b0;
                wb_cyc <= 1'b0;
                wb_stb <= 1'b0;
            end
        end
    end

    // OpenCores i2c_master_top uses 3-bit register indices, 8-bit data, and
    // standard Wishbone CYC/STB/WE/ACK. The SoC's word index maps directly to
    // the OpenCores register index because each register is spaced by 4 bytes.
    i2c_master_top #(
        .ARST_LVL(1'b1)
    ) u_i2c_master_top (
        .wb_clk_i      (clk),
        .wb_rst_i      (~resetn),
        .arst_i        (~resetn),
        .wb_adr_i      (req_addr),
        .wb_dat_i      (req_wdata),
        .wb_dat_o      (wb_rdata),
        .wb_we_i       (req_we),
        .wb_stb_i      (wb_stb),
        .wb_cyc_i      (wb_cyc),
        .wb_ack_o      (wb_ack),
        .wb_inta_o     (wb_irq),
        .scl_pad_i     (scl_i),
        .scl_pad_o     (scl_pad_o),
        .scl_padoen_o  (scl_padoen_o),
        .sda_pad_i     (sda_i),
        .sda_pad_o     (sda_pad_o),
        .sda_padoen_o  (sda_padoen_o)
    );

endmodule
