/* VFDHackICE */
// TSPI - Tri SPI. Specially designed for MN15439A, Vacuum Fluorescent Display Dot Matrix Graphic Display.
// Capable of producing 8 levels grayscale (including Dot turned of).
// Running on Lattice iCE40LP1K little tiny FPGA using iCESugar nano board.
// Coded by TinLethax 2021/11/15 +7

// Tri SPI low level interface.
module TSPI(input CLK, 
	output SOUT1, 
	output SOUT2, 
	output SOUT3, 
	output S_CLK, 
	input SCE, 
	input [5:0] GN,
	
	// These will connect to Slave SPI module.
	output reg [11:0] MEM_ADDR,
	input [7:0] MEM_BYTE,
	output reg MEM_CE // active high to read.
	);

// regs for control GPIO
reg SD1, SD2, SD3;
// assign each Serial output pins to regs 
assign SOUT1 = SD1;
assign SOUT2 = SD2;
assign SOUT3 = SD3;

// Keep track of current bit that shifting out.
reg [9:0] BitCounter;

// LUTs for converting the (MSB)abcdef(LSB) to (MSB)afbecd(LSB) format require by display.
reg [1:0] ConvLUT [5:0]; 
reg [1:0] pixLUT [5:0];

// Tri-SPI clock running the same freq as System clock.
// But can be completely disabled by set SCE to 0.
assign S_CLK = CLK & SCE;

initial begin
	BitCounter = 0;

	SD1 = 0;
	SD2 = 0;
	SD3 = 0;
	ConvLUT[0] = 3;//a
	ConvLUT[1] = 0;//f
	ConvLUT[2] = 0;//b
	ConvLUT[3] = 3;//e
	ConvLUT[4] = 3;//c
	ConvLUT[5] = 0;//d
	
	pixLUT[0] = 0;
	pixLUT[1] = 2;
	pixLUT[2] = 0;
	pixLUT[3] = 2;
	pixLUT[4] = 1;
	pixLUT[5] = 1;
	
end


always@(posedge S_CLK) begin 

		if(BitCounter == 288)
			BitCounter <= 0;// reset the counter.
		else 
			BitCounter <= BitCounter + 1;// count bit number / clock cycle.

		/* use BitCounter to calculate the memory offset to shift data out.
		// We treat the plain linear 3003 bytes mem as 77 byte wide (column) and 39 byte tall (roll).
		// Col0		Col1	Col2	...	Col76
		// [Byte0]	[Byte1]	[Byte2]	... [Byte76] --- ROW0
		// [Byte77] [Byte78] [Byte79] ... [Byte153] --- ROW1
		//						...
		//						...
		// [Byte2926] [Byte2927] [Byte2928] ... [Byte3003] --- ROW38
		
		// 2 Grids share same 6 bit-wide data, We send 6bit pixels data for 39 times (Vertically from to to bottom in perspective of Display dot arrangement).
		
		// GN / 2 -> will gives us as if Grid N or N+1 in currently displaying, Which byte column we need to read from Display "mem"
		// BitCounter/6 -> serve as a "every 6 bit" counter, every time 6 bit has been send, we move to new row but still in the same column.
		// from that be can calculate the absolute position of byte on array by multiply by column number (77).
		// (BitCounter/6)*77 -> give us the absolute position of byte, so we can read array in verical manner.
		
		// Sum everyting up we'll have
		// (GN / 2) + (BitCounter / 6)*77
		
		// In the part of bit shifting, we have to loob counting 0 1 2 3 4 5 0 1 2 3 4 5 ... becase bit shift is a maksing to check whether that pixel bit is 1 or 0,
		// so we can shift them out correctly. To calculate and the the 0-5 loop count everytime bit counter increase (with clock cycle).
		// utilizing modulo, modulo is operation in Math that returns you "remain" of division instead of "division product"
		// Bitcounter % 6 -> Will give us 0-5 output.
		
		// Note that I use && instead of &, that because I want the check bit not to do "and" operation.
		// This will returns either 1 or 0. 1 means that bit on "mem" is = 1 thus pixel on and vice versa.*/
		
		
		// TODO : Make the "turn grid on" work.
		if(BitCounter < 234)// Bit 0 - 233 are pixel data
			begin
			// Store mem Address to this. and later read data from MEM_BYTE;
			MEM_CE <= 1;
			//MEM_ADDR <= (GN / 2) + (BitCounter / 6)*77;
			MEM_ADDR <= /*on ram afbecd pixel column locator*/pixLUT[BitCounter%6] + /*Grid number select byte 0,1,2 3,4,5 or so on*/ 3*(GN/2) + /* row selector */ (BitCounter / 6)*77;
			
			//ConvLUT use for switching between a,c,e or b,d,f on memory byte 
			// since the structure looks like this 00aaabbb 00cccddd 00eeefff and repeat. 
			SD1 <= MEM_BYTE && (1 << ((BitCounter % 6) + ConvLUT[BitCounter%6]));
			SD2 <= MEM_BYTE && (1 << ((BitCounter % 6)+ 1 + ConvLUT[BitCounter%6]));// + 1 to shift to 2nd bit of Grayscale bit.
			SD3 <= MEM_BYTE	&& (1 << ((BitCounter % 6)+ 2 + ConvLUT[BitCounter%6]));// +2 to shift to 3rd bit of Grayscale bit.
			end
		
		// after bit 233, bit 234 (and so on) are Grid Number bit.
		// These 2 ifs will turn Grid N and N+1 on 
	
		if(BitCounter == (GN + 233)) begin// Grid N
			SD1 <= 1;
			SD2 <= 1;
			SD3 <= 1;
			end
		else begin
			SD1 <= 0;
			SD2 <= 0;
			SD3 <= 0;
			end
		
		if(BitCounter == (GN + 234)) begin// Grid N+1
			SD1 <= 1;
			SD2 <= 1;
			SD3 <= 1;
			end
		else begin
			SD1 <= 0;
			SD2 <= 0;
			SD3 <= 0;
			end
		
end

endmodule //TSPI


// Grayscale signal generater. GCP stands for Gradient Control Pulse
module GCPCLK(
	input CLK, 
	output reg GCP, 
	input PCE);

integer counter; // keep track of SPI clock to generate proper GCP signal, counting from 0 to 287.

// This is similar to declaring variable in void main() in c
initial begin 
	counter = 0;
end


// counting every clock cycle.
always @(posedge CLK & PCE) begin
		
	if(counter == 288)// count clock cycles.
		counter <= 0;
	else 
		counter <= counter + 1;// increase counter by 1, non blocking counter (free running).
		
	case(counter)// these cases, after certain clock cycles, 
	//we need to generate short pulse for VFD in order to get proper PWM for each brightness level.
		72,// 1st pulse after 72 clock cycles.
		144,// 2nd pulse after 144 clock cycles.
		192,// 3rd pulse after 192 clock cycles.
		216,// 4th pulse after 216 clock cycles.
		240,// 5th pulse after 240 clock cycles.
		256: begin// 6th pulse after 256 clock cycles.
			GCP = 1;
			#1
			GCP = 0;
		end
		default: GCP = 0;
	endcase
	
end //always@

endmodule// GCPCLK

// Slave SPI module, Host -> FPGA
module SSPI (
	input MOSI,
	input SCLK,
	input SCE,
	
	input [11:0]M_ADDR,
	output reg [7:0]M_BYTE,
	input M_CE
	);
	
//reg [7:0] SPIbuffer;
reg [11:0] byteBufCnt;// 12 bit counter for 3003 bytes data + 1 CMD bytes.
reg [2:0] bitBufCnt;// 3-bit counter from 0-7


// RAM thingy.
// Using Embeded Block RAM for Display buffer 
// Taken from TN1250 - Memory Usage Guide for iCE40 Devices 

// We need total of 3003 Bytes of RAM, That equal to 24024 bits or memory
// Each Block Ram consist of 4096 bits
// In total we need 6 Blocks.

// We mimick the Dual port BRAM (Since it requires separate R,W clock cycle, we can read it at the same time).
// by just share Read clock and Write clock, Viola! Dual port R/W synced!

reg [7:0] mem [3003:0];
integer r;

initial mem[0] = 255;// some init.

always@(posedge SCLK & ~SCE) begin

		if(!bitBufCnt) begin
			bitBufCnt <= 0;
			byteBufCnt++;
			end
		else
			bitBufCnt <= bitBufCnt + 1;// keep tack of bit 		
			
		mem[byteBufCnt] <= mem[byteBufCnt] | (MOSI << bitBufCnt);// storing each bit into 8bit reg.

		if(M_CE)
			M_BYTE <= mem[M_ADDR];
		else 
			M_BYTE <= 'hFF;
	
end// always@

endmodule


module top(input CLK, 
	output wire S1, // Serial data 1 (VFD)
	output wire S2, // Serial data 2 (VFD)
	output wire S3, // Serial data 3 (VFD)
	output wire BLK, // Display Blanking (VFD)
	output wire LAT, // Serial Latch (VFD)
	output wire PWM, // Gradient Control Pulse (VFD)
	output wire SCK, // Serial Clock (VFD)
	input SSI, // Master out Slave in SPI (Host to FPGA)
	input SSCK, // Slave SPI clock input (Host to FPGA)
	input SCS); // Chip select (Active Low, controlled by Host).

// Clock divider to get 60MHz
reg clk_fps = 0;// pesudo clock for display refreshing, aiming for 0 fps (60Hz).
reg [17:0] clk_60Hz = 17'b0;

// these set to 1 after pulsed BLK and LAT pin.
reg SPI_start = 0;

// store the current VFD gate number
reg [5:0] GridNum = 0; //store grid number from 1 to 52 (52 grids), I'll automatically start at 1 later on.

// BLANK and LATCH control thingy
reg BLK_CTRL, LAT_CTRL;
assign BLK = BLK_CTRL;
assign LAT = LAT_CTRL;

// Memory related regs
wire [11:0] GRAM_ADDR; // Graphic RAM address, just the alternative name of MEM_ADDR.
wire [7:0] GRAM_BYTE;
wire GRAM_CE;

// Gradient Control Pulse 
GCPCLK Gradient(
	.CLK(CLK), 
	.GCP(PWM), 
	.PCE(SPI_start)
	);// parse the PWM pin (actual physical output) to GCP module.

// Tri-SPI PHY.
TSPI SerialOut(
	.CLK(CLK), 
	.SOUT1(S1), 
	.SOUT2(S2), 
	.SOUT3(S3), 
	.S_CLK(SCK), 
	
	.SCE(SPI_start), 
	.GN(GridNum),
	
	.MEM_ADDR(GRAM_ADDR),
	.MEM_BYTE(GRAM_BYTE),
	.MEM_CE(GRAM_CE)
	);// parse all necessary pins for Tri SPI.

// Slave SPI PHY
SSPI SerialIN(
	.MOSI(SSI), 
	.SCLK(SSCK), 
	.SCE(SCS),
	
	.M_ADDR(GRAM_ADDR),
	.M_BYTE(GRAM_BYTE),
	.M_CE(GRAM_CE)
	);// parse all pins for using as Slave SPI device.


// Things that work at System clock 
always@(posedge CLK) begin
	
	// Generate 60Hz clock for display refreshing. Generated from 12MHz input clock
	clk_60Hz <= clk_60Hz + 1;
	if(clk_60Hz == 100000) begin
		clk_fps <= ~clk_fps;
		clk_60Hz <= 17'b0;
	end
	
end

// Generate this part every 1/60 sec.
always@(posedge clk_fps) begin
	// total time 25us 
	
	// Start Tranmission by Display blanking
	BLK_CTRL = 1'b1;
	#1
	LAT_CTRL = 1'b1;
	#5		//400ns delay (at 12MHz clock)
	LAT_CTRL = 1'b0;
	#1
	BLK_CTRL = 1'b0;
	
	//output SPI data and generate GCP at the same time.
	
	if(GridNum == 53)// MN15439A has 52 Grids, reset them when exceed 52.
		GridNum <= 0;
	else
		GridNum <= GridNum + 1;
		
	if(SCS)
		SPI_start = 1;
	else
		SPI_start = 0;
end


endmodule// top