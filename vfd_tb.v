// VFDHackiCE testbench.
// Coded by TinLethax 2022/05/18 +7
`timescale 10ns/10ns
`include "main.v"

module testbench();

reg simclk = 0;

wire SER0;
wire SER1;
wire SER2;
wire BLANK;
wire LATCH;
wire GCPWM;
wire VFDCLK;

reg scs = 1;

initial begin
	$dumpfile("vfdhacice.vcd"); 
	$dumpvars(0, testbench);
end

always begin
	#4
	simclk <= ~simclk;
end

top vfd(
	.SYS_CLK(simclk),
	
	.S1(SER0),
	.S2(SER1),
	.S3(SER2),
	.BLK(BLANK),
	.LAT(LATCH),
	.PWM(GCPWM),
	.SCK(VFDCLK),
	
	.SSI(1'b0),
	.SSCK(1'b0),
	.SCS(scs)
	);

endmodule