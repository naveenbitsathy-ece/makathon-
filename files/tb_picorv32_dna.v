`timescale 1 ns / 1 ps

// ============================================================================
// Testbench:    tb_picorv32_dna
// Project:      PicoRV32-Based DNA Sequence Analysis and Motif Detection
// Description:  Full-system integration testbench verifying that the PicoRV32
//               processor executes firmware to control the DNA accelerator
//               through MMIO, reads the result, and outputs the verification text.
// ============================================================================

module tb_picorv32_dna;

	reg clk = 1'b0;
	always #5 clk = ~clk;  // 100 MHz clock (10 ns period)

	reg resetn = 1'b0;

	initial begin
		$dumpfile("tb_picorv32_dna.vcd");
		$dumpvars(0, tb_picorv32_dna);

		// Hold reset for 100 clock cycles
		repeat (100) @(posedge clk);
		resetn <= 1'b1;
	end

	wire trap;
	wire [7:0] out_byte;
	wire out_byte_en;

	// ------------------------------------------------------------------------
	// Instantiate Top-Level SoC System
	// ------------------------------------------------------------------------
	system uut (
		.clk        (clk        ),
		.resetn     (resetn     ),
		.trap       (trap       ),
		.out_byte   (out_byte   ),
		.out_byte_en(out_byte_en)
	);

	// ------------------------------------------------------------------------
	// Capture UART Output and Display on Console
	// ------------------------------------------------------------------------
	reg [7:0] p0 = 0, p1 = 0, p2 = 0, p3 = 0, p4 = 0, p5 = 0;
	always @(posedge clk) begin
		if (resetn && out_byte_en) begin
			$write("%c", out_byte);
			$fflush;
			p0 <= p1; p1 <= p2; p2 <= p3; p3 <= p4; p4 <= p5; p5 <= out_byte;
			if ({p1, p2, p3, p4, p5, out_byte} == 48'h504153534544) begin // "PASSED"
				#10000;
				$finish;
			end
		end
		if (resetn && trap) begin
			$finish;
		end
	end

	// ------------------------------------------------------------------------
	// Watchdog Timer to Catch Hangs
	// ------------------------------------------------------------------------
	initial begin
		#5000000; // 5 ms timeout
		$display("\n[ERROR] Simulation timed out!");
		$finish;
	end

endmodule
