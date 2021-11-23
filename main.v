/* VFDHackICE */
// TSPI - Tri SPI. Specially designed for MN15439A, Vacuum Fluorescent Display Dot Matrix Graphic Display.
// Capable of producing 8 levels grayscale (including Dot turned of).
// Running on Lattice iCE40LP1K little tiny FPGA using iCESugar nano board.
// Coded by TinLethax 2021/11/15 +7

// Tri SPI low level interface.
module TSPI(input CLK, 
	output reg [2:0]SOUT, 
	output S_CLK, 
	input SCE, 
	input [5:0] GN,
	
	// These will connect to Slave SPI module.
	output reg [11:0] MEM_ADDR,
	input [7:0] MEM_BYTE,
	output wire MEM_CE // active high to read.
	);


// Keep track of current bit that shifting out.
reg [9:0] BitCounter;

// Count 0-6 instead of using modulo
reg [2:0] Mod1;

// LUT for converting the (MSB)abcdef(LSB) to (MSB)afbecd(LSB) format require by display.
reg [1:0] pixLUT [5:0];

// LUT for GRAM row select
reg [11:0] RowSel [38:0];

// reg store value to count to 39 (completed 1 column).
reg [6:0] clk_cnt39 = 0;

integer i;

// Tri-SPI clock running the same freq as System clock.
// But can be completely disabled by set SCE to 0.
assign S_CLK = CLK & SCE;
assign MEM_CE = SCE;


initial begin
	BitCounter <= 0;

	Mod1 <= 0;
	
	for(i=0; i < 39;i = i+1)
		RowSel[i] <= (77*i);
	
	pixLUT[0] <= 0;
	pixLUT[1] <= 2;
	pixLUT[2] <= 0;
	pixLUT[3] <= 2;
	pixLUT[4] <= 1;
	pixLUT[5] <= 1;
	
end


always@(negedge SCE) begin
	// reset value when data transmitted.
	Mod1 <= 0;
	BitCounter <= 0;
end

always@(posedge S_CLK) begin 

	if(BitCounter == 287) begin
		BitCounter <= 0;// reset the counter.
		clk_cnt39 <= 0;// reset the "send the pixels data 6bit 39 times" counter. 
		end
	else 
		BitCounter <= BitCounter + 1;// count bit number / clock cycle.
	
	if(Mod1 == 5)
		Mod1 <= 0;
	else begin
		Mod1 <= Mod1 + 1;
		clk_cnt39 <= clk_cnt39 + 1;
	end

		
	//use BitCounter to calculate the memory offset to shift data out.
	// We treat the plain linear 3003 bytes mem as 77 byte wide (column) and 39 byte tall (roll).
	// Col0		Col1	Col2	...	Col76
	// [Byte0]	[Byte1]	[Byte2]	... [Byte76] --- ROW0
	// [Byte77] [Byte78] [Byte79] ... [Byte153] --- ROW1
	//						...
	//						...
	// [Byte2926] [Byte2927] [Byte2928] ... [Byte3002] --- ROW38
	
	// 2 Grids share same 6 bit-wide data, We send 6bit pixels data for 39 times (Vertically from to to bottom in perspective of Display dot arrangement).
	
		
	// send 6 pixels 39 times took 234 clock cycle, after 234 cycles, we'll send the Grid control data.
	if(clk_cnt39 < 39) begin// Send Pixels data.
	
		MEM_ADDR <= pixLUT[Mod1]; // Locate the byte containing A,B,C,D,E or F pixel 
		MEM_ADDR <= MEM_ADDR + (GN*3 >> 1);// Grid number will determine which column on GRAM will be selected.
		MEM_ADDR <= MEM_ADDR + RowSel[clk_cnt39];// This will move to new row on GRAM.
		
		if(BitCounter%2)
			SOUT[2:0] <= MEM_BYTE[2:0];
		else
			SOUT[2:0] <= MEM_BYTE[5:3];
			
	end
	else begin// Send Grid Control data.
		// after bit 233, bit 234 (and so on) are Grid Number bit.
		// These 2 ifs will turn Grid N and N+1 on 
		if(BitCounter == (GN+233)) begin
			repeat(2)// repeat this 2 clock cycle
				SOUT[2:0] <= 3'b111;
		end else
			SOUT[2:0] <= 3'b000;
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
	counter <= 0;
end


// counting every clock cycle.
always @(posedge CLK & PCE) begin
		
	if(counter == 287)// count clock cycles.
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
	
	output reg [11:0]M_ADDR,
	output reg [7:0]M_BYTE,
	output reg M_CE
	);
	
reg [7:0] SPIbuffer;
reg [11:0] byteBufCnt;// 12 bit counter for 3003 bytes data + 1 CMD bytes.
reg [2:0] bitBufCnt;// 3-bit counter from 0-7

always@(posedge SCLK & ~SCE) begin

		if(!bitBufCnt) begin// every 8 clock cycle.
			bitBufCnt <= 0;// reset bit counter 
			byteBufCnt <= byteBufCnt + 1;// counting how many bytes have been sampled.
			M_BYTE <= SPIbuffer;// copy the freshly made byte to mem.
			M_CE <= 1;// at the same time, turn write enable on.
			end
		else
			bitBufCnt <= bitBufCnt + 1;// keep tack of bit 		
		
		M_ADDR <= byteBufCnt;// byte counter keep tracks of memory address (byte number 0 = mem[0], byte number 1 = mem[1] and so on).
			
		SPIbuffer[bitBufCnt] <= MOSI;// storing each bit into 8bit reg.
	
end// always@

// Host release SPI chip select. logic lvl goes back to HIGH
always@(posedge SCE)begin
	M_CE = 0;// DIsable mem write.
	bitBufCnt = 0;// reset counter
	byteBufCnt = 0;// reset byte counter.
end

endmodule

// Using BRAM as Graphic RAM.
module GRAM(
	input CLK,
	input W_CLK,
	
	input [7:0]GRAM_IN,
	output reg [7:0]GRAM_OUT,
	
	input [11:0] GRAM_ADDR_R,
	input [11:0] GRAM_ADDR_W,
	
	input G_CE_W,
	input G_CE_R);
	
reg [7:0] mem [3003:0];

initial mem[0] <= 255;

always@(posedge CLK) begin// reading from RAM sync with system clock 
	if(G_CE_R)
		GRAM_OUT <= mem[GRAM_ADDR_R];	
end	

always@(posedge W_CLK) begin// writing to RAM sync with Slave SPI clock.
	if(G_CE_W)
		mem[GRAM_ADDR_W] <= GRAM_IN;
end
	
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

wire [11:0] GRAM_ADDR_W_SPI;
wire [7:0] GRAM_SPI_READ;
wire GRAM_CEW;

// Gradient Control Pulse 
GCPCLK Gradient(
	.CLK(CLK), 
	.GCP(PWM), 
	.PCE(SPI_start)
	);// parse the PWM pin (actual physical output) to GCP module.

// Tri-SPI PHY.
TSPI SerialOut(
	.CLK(CLK), 
	.SOUT({S3,S2,S1}),
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
	
	.M_ADDR(GRAM_ADDR_W_SPI),
	.M_BYTE(GRAM_SPI_READ),
	.M_CE(GRAM_CEW)
	);// parse all pins for using as Slave SPI device.

GRAM GraphicRAM(
	.CLK(CLK),
	.W_CLK(SSCK),
	
	// Mem writeto part, used by Slave SPI.
	.GRAM_IN(GRAM_SPI_READ),
	.GRAM_ADDR_W(GRAM_ADDR_W_SPI),
	.G_CE_W(GRAM_CEW),
	
	// Mem readback part, used by Tri-SPI module
	.GRAM_OUT(GRAM_BYTE),
	.GRAM_ADDR_R(GRAM_ADDR),
	.G_CE_R(GRAM_CE)
	);// parse all regs and wires for GRAM.
	

// Things that work at System clock 
always@(posedge CLK) begin
	
	// Generate 60Hz clock for display refreshing. Generated from 12MHz input clock
	// actually it's 3120Hz (each frame need to update display 52 times (52 grids), we want 60fps, 1 frame last 1/(60*52) second).
	// 1/(60*52) = 320us,  3.2e-4 * 1.2e7(Hz) = 3840 <- use in if compare. 
	clk_60Hz <= clk_60Hz + 1;
	if(clk_60Hz == 3839) begin
		clk_fps <= ~clk_fps;
		clk_60Hz <= 17'b0;
	end
	
end

// Generate this part every 1/3120 sec.
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
	
	if(GridNum == 52)// MN15439A has 52 Grids, reset them when exceed 52.
		GridNum <= 1;
	else
		GridNum <= GridNum + 1;
		
	if(SCS)
		SPI_start = 1;
	else
		SPI_start = 0;
end


endmodule// top