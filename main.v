// VFDHackICE project. MN15439A Noritake Itron VFD display controller + Buffer.
// Implemented Tri-SPI PHY. A Tripple Serial data output, 3 bit splitted to each data line. to control 8 levels Grayscale.
// Plus Variable frequency to generate GCP signal, Which is PWM of each brightness level combined in single signal. 
// Running on Lattice iCE40LP1K little tiny FPGA using iCESugar nano board.
// Coded by TinLethax 2021/11/15 +7
// Updated on 2022/04/27 +7

// =================================
// ======= Slave SPI PHY ===========
// =================================

// Slave SPI module, Host -> FPGA
module SSPI (
	input MOSI,
	input SCLK,
	input CE,
	
	output reg [11:0]M_ADDR,
	output reg [7:0]M_BYTE,
	output reg M_CE
	);
	
reg [7:0] SPIbuffer;
reg [11:0] byteBufCnt;// 12 bit counter for 3003 bytes data + 1 CMD bytes.
reg [3:0] bitBufCnt;// 3-bit counter from 0-7


always@(posedge SCLK) begin

if(~CE) begin
		bitBufCnt <= bitBufCnt + 1;// keep tack of bit 
		
		if(bitBufCnt == 8) begin// every 8 clock cycle (or 8 data bit).
			bitBufCnt <= 0;// reset bit counter 
			byteBufCnt <= byteBufCnt + 1;// counting how many bytes have been sampled.
			M_BYTE <= SPIbuffer;// copy the freshly made byte to mem.
			M_CE <= 1;// at the same time, turn write enable on.
		end
		else
			M_CE <= 0;
		
					
		M_ADDR <= byteBufCnt;// byte counter keep tracks of memory address (byte number 0 = mem[0], byte number 1 = mem[1] and so on).
			
		SPIbuffer[bitBufCnt] <= MOSI;// storing each bit into 8bit reg.
end 
else begin// Host release SPI chip select. CE logic lvl goes back to HIGH
	M_CE <= 0;// Disable mem write.
	bitBufCnt <= 0;// reset counter
	byteBufCnt <= 0;// reset byte counter.
end

end// always@

endmodule// SSPI


// =================================
// ======= Graphic MEM =============
// =================================

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
	
reg [7:0] mem [3002:0];

integer fill=0;

initial begin
	for(fill = 0;fill < 3003; fill++) 
		mem[fill] <= 8'b00000111;// initialize BRAM as BLANK.
end

always@(posedge CLK) begin// reading from RAM sync with system clock 
	if(G_CE_R)
		GRAM_OUT <= mem[GRAM_ADDR_R];	
end	

always@(posedge W_CLK) begin// writing to RAM sync with Slave SPI clock.
	if(G_CE_W)
		mem[GRAM_ADDR_W] <= GRAM_IN;
end
	
endmodule// GRAM


module top(input SYS_CLK, 
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

// BLANK and LATCH control thingy
reg BLK_CTRL = 0, LAT_CTRL = 0;
assign BLK = BLK_CTRL;
assign LAT = LAT_CTRL;

// Memory related regs
reg [11:0] GRAM_ADDR = 0; // Graphic RAM address, just the alternative name of MEM_ADDR.
wire [7:0] GRAM_BYTE;
reg GRAM_CE;

wire [11:0] GRAM_ADDR_W_SPI;
wire [7:0] GRAM_SPI_READ;
wire GRAM_CEW;

reg vfd_clk = 0;
assign SCK = vfd_clk;

// Slave SPI PHY
SSPI SerialIN(
	.MOSI(SSI), 
	.SCLK(SSCK), 
	.CE(SCS),
	
	.M_ADDR(GRAM_ADDR_W_SPI),
	.M_BYTE(GRAM_SPI_READ),
	.M_CE(GRAM_CEW)
	);// parse all pins for using as Slave SPI device.

GRAM GraphicRAM(
	.CLK(SYS_CLK),
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

// Serial output reg
reg [2:0]SOUT = 0;
assign S1 = SOUT[0];
assign S2 = SOUT[1];
assign S3 = SOUT[2];

// GCP output reg
reg GCP = 0;
assign PWM = GCP;

// Grid Number
reg [5:0]GN = 0;

// Keep track of current bit that shifting out.
reg [9:0] BitCounter = 0;

// Count 0-5 instead of using modulo.
reg [2:0] Mod6 = 0;

// LUT for converting the (MSB)abcdef(LSB) to (MSB)afbecd(LSB) format require by display.
reg [1:0] pixLUT [5:0];

// LUT for GRAM row select.
reg [11:0] RowSel [38:0];

// LUT for blocking certain pixel group, When Grid with Odd number will only turns A B and C column on, Grid with Even number is vise versa.
reg [2:0] pixBlock [1:0][5:0];

// LUT to replace multiplication with 3 of Grid number, use for move byte column offset that read from GRAM.
reg [7:0] ColSel [51:0];

// reg store value to count to 39 (completed 1 column).
reg [6:0] clk_cnt39 = 0;

// use in for loop.
integer i,j;

// For FSM
reg [1:0]main_fsm = 0;
reg [1:0]bram_fsm = 0;
reg [2:0]BL_CTRL = 0;

// main FSM
always@(posedge SYS_CLK)begin

if(SCS) begin // Gating with SCS pin, will start when Host release CS pin.
	case(main_fsm)
	0:begin// VFD Blank and Latch control.
	
		// Initialize default values.
		BitCounter <= 0;
		SOUT[2:0] <= 3'b0;
		Mod6 <= 0;

		
		// LUT Const stuffs 
		for(i=0; i < 39;i = i+1)
			RowSel[i] <= (77*i);
			
		for(j=0; j < 52;j = j+1)
			ColSel[j] <= (j/2) * 3;

		pixLUT[0] <= 0;// A
		pixLUT[1] <= 2;// F
		pixLUT[2] <= 0;// B
		pixLUT[3] <= 2;// E
		pixLUT[4] <= 1;// C
		pixLUT[5] <= 1;// D
		
		// some pixel columns need to be turned of depend on Odd or Even grid number currently selected.
		//pixBlock[GN%2][Mod6]
		// GN%2 = 0, Grid is even number, turn on only DEF
		pixBlock[0][0] <= 3'b000;// A off
		pixBlock[0][1] <= 3'b111;// F on
		pixBlock[0][2] <= 3'b000;// B off
		pixBlock[0][3] <= 3'b111;// E on
		pixBlock[0][4] <= 3'b000;// C off
		pixBlock[0][5] <= 3'b111;// D on
		// GN%2 = 1, Grid is odd number, turn on only ABC
		pixBlock[1][0] <= 3'b111;// A on
		pixBlock[1][1] <= 3'b000;// F off
		pixBlock[1][2] <= 3'b111;// B on
		pixBlock[1][3] <= 3'b000;// E off
		pixBlock[1][4] <= 3'b111;// C on
		pixBlock[1][5] <= 3'b000;// D off
	
	
		BL_CTRL <= BL_CTRL + 1;
		if(BL_CTRL == 0)begin
			BLK_CTRL <= 1;
		end
		
		if(BL_CTRL == 1)begin
			LAT_CTRL <= 1;
		end
		
		if(BL_CTRL == 5)begin// after 5 clock cycle at 12MHz, bring LAT down.
			LAT_CTRL <= 0;
		end
		
		if(BL_CTRL == 6)begin// after 6 clock cycles at 12<Hz, bring Blank down.
			BLK_CTRL <= 0;
			BL_CTRL <= 0;
			main_fsm <= 1;// move to next main fsm stage, Write BRAM read address.
		end
	
	end
	
	1:begin// select BRAM Address.
		vfd_clk <= 0;
		
		case(bram_fsm)// state machine for reading BRAM (framebuffer).
		0: begin // Read Enable.
			GRAM_CE <= 1;
			bram_fsm <= 1;
		end
		
		1: begin// Write read address to BRAM
			// pixLUT[] is look up table to locate which pixel is where on the Memory. Memory format looks like this.
			//  [Byte 0]  [Byte 1]  [Byte 2]
			// [00AAABBB][00CCCDDD][00EEEFFF]
			// normally Display only accept this weird AFBECD pixels order. assign each pixels to number and we'll get.
			// A=0, F=1, B=2, E=3, C=4, D=5. Putting these number into [] of pixLut will return the Byte number, indicates where to look for "that" pixel 3bit data.
		
			// ColSel[GN-1] is used for moving column 3 byte each step.
			// grid 1 and 2, grid 3 and 4, 5 and 6 and so on, shares same 3 byte column, because 1 column contain 2 pixels data. each time display update, we send 3 column to display.
			// This will calculate where the column of byte contain pixels when It's Grid number X.
		
			// RowSel[] is array store the multiple of 77, since we treat (Graphic) Memory as 77 byte wide and 39 row tall. 
			// new row of byte start at 77*n where n is row number starting from 0.
			// that array doesn't require clock cycles to multiply, instead just grab number from LUT which is synthesized by Yosys.
			// Note that for loop will be optimized, value RowSel[0] to RowSel[38] will be pre-calculated by synthesizer. 
			
			GRAM_ADDR <= pixLUT[Mod6] + ColSel[GN-1] + RowSel[clk_cnt39];
			
			bram_fsm <= 2;
		end
		
		2: begin// wait until data is stable to read, and move forward the main fsm, By the time that main fsm is moved to stage 2, the data is ready to read.
			bram_fsm <= 1;
			main_fsm <= 2;
		end
		
		endcase// bram_fsm
	
	end
	
	2:begin// Shift out to VFD display and do the GCP signal generation.
		vfd_clk <= 1;
		
		// When 1 Column / Grid number data is wrote to the Display. main fsm goes back to Blank / Lat control.
		// Keep track of clock cycle, we send 288bit worth of data.
		BitCounter <= BitCounter + 1;// count bit number / clock cycle.
		if(BitCounter == 287)begin
			BitCounter <= 0;
			main_fsm <= 0;
			
			Mod6 <= 0;
			clk_cnt39 <= 0;
			GN <= GN + 1;// move to next grid.
			if(GN == 52)begin// On next clock cycle, reset Grid Number to 1
				GN <= 1;
			end
		end
		else begin
			main_fsm <= 1;// back to BRAM write read address.
		end
	
		// Mod 6 counter, 0 1 2 3 4 5 then back to 0 
		Mod6 <= Mod6 + 1;
		if(Mod6 == 5) begin 
			Mod6 <= 0;// reset the mod counter.
			clk_cnt39 <= clk_cnt39 + 1;// keep track of how many times 6bit pixels have been sent.
			if(clk_cnt39 <= 38)
				clk_cnt39 <= 0;
		end 
			
// =================================
// ======= Data Shifting ===========
// =================================
	
		if(BitCounter < 234) begin// Send Pixels data.
			
			case(Mod6)// some pixel column read from [2:0] some read from [5:3]
				0: SOUT[2:0] <= GRAM_BYTE[5:3] & pixBlock[GN%2][Mod6];// A
				1: SOUT[2:0] <= GRAM_BYTE[2:0] & pixBlock[GN%2][Mod6];// F
				2: SOUT[2:0] <= GRAM_BYTE[2:0] & pixBlock[GN%2][Mod6];// B
				3: SOUT[2:0] <= GRAM_BYTE[5:3] & pixBlock[GN%2][Mod6];// E
				4: SOUT[2:0] <= GRAM_BYTE[5:3] & pixBlock[GN%2][Mod6];// C
				5: SOUT[2:0] <= GRAM_BYTE[2:0] & pixBlock[GN%2][Mod6];// D
			endcase
				
		end
		else begin// Send Grid Control data.
			// after bit 233, bit 234 (and so on) are Grid Number bit.
			// These case statement will turn Grid N and N+1 on 
			// I know it's reallly messy (I literally manually type it all and copy and paste xD.).
			// But it really working. So, if it works, don't touch it.
			case(GN) 
				1: SOUT[2:0] <= ((BitCounter == 234) || (BitCounter == 235)) ? 3'b111 : 3'b000;
				2: SOUT[2:0] <= ((BitCounter == 235) || (BitCounter == 236)) ? 3'b111 : 3'b000;
				3: SOUT[2:0] <= ((BitCounter == 236) || (BitCounter == 237)) ? 3'b111 : 3'b000;
				4: SOUT[2:0] <= ((BitCounter == 237) || (BitCounter == 238)) ? 3'b111 : 3'b000;
				5: SOUT[2:0] <= ((BitCounter == 238) || (BitCounter == 239)) ? 3'b111 : 3'b000;
				6: SOUT[2:0] <= ((BitCounter == 239) || (BitCounter == 240)) ? 3'b111 : 3'b000;
				7: SOUT[2:0] <= ((BitCounter == 240) || (BitCounter == 241)) ? 3'b111 : 3'b000;
				8: SOUT[2:0] <= ((BitCounter == 241) || (BitCounter == 242)) ? 3'b111 : 3'b000;
				9: SOUT[2:0] <= ((BitCounter == 242) || (BitCounter == 243)) ? 3'b111 : 3'b000;
				10: SOUT[2:0] <= ((BitCounter == 243) || (BitCounter == 244)) ? 3'b111 : 3'b000;
				11: SOUT[2:0] <= ((BitCounter == 244) || (BitCounter == 245)) ? 3'b111 : 3'b000;
				12: SOUT[2:0] <= ((BitCounter == 245) || (BitCounter == 246)) ? 3'b111 : 3'b000;
				13: SOUT[2:0] <= ((BitCounter == 246) || (BitCounter == 247)) ? 3'b111 : 3'b000;
				14: SOUT[2:0] <= ((BitCounter == 247) || (BitCounter == 248)) ? 3'b111 : 3'b000;
				15: SOUT[2:0] <= ((BitCounter == 248) || (BitCounter == 249)) ? 3'b111 : 3'b000;
				16: SOUT[2:0] <= ((BitCounter == 249) || (BitCounter == 250)) ? 3'b111 : 3'b000;
				17: SOUT[2:0] <= ((BitCounter == 250) || (BitCounter == 251)) ? 3'b111 : 3'b000;
				18: SOUT[2:0] <= ((BitCounter == 251) || (BitCounter == 252)) ? 3'b111 : 3'b000;
				19: SOUT[2:0] <= ((BitCounter == 252) || (BitCounter == 253)) ? 3'b111 : 3'b000;
				20: SOUT[2:0] <= ((BitCounter == 253) || (BitCounter == 254)) ? 3'b111 : 3'b000;
				21: SOUT[2:0] <= ((BitCounter == 254) || (BitCounter == 255)) ? 3'b111 : 3'b000;
				22: SOUT[2:0] <= ((BitCounter == 255) || (BitCounter == 256)) ? 3'b111 : 3'b000;
				23: SOUT[2:0] <= ((BitCounter == 256) || (BitCounter == 257)) ? 3'b111 : 3'b000;
				24: SOUT[2:0] <= ((BitCounter == 257) || (BitCounter == 258)) ? 3'b111 : 3'b000;
				25: SOUT[2:0] <= ((BitCounter == 258) || (BitCounter == 259)) ? 3'b111 : 3'b000;
				26: SOUT[2:0] <= ((BitCounter == 259) || (BitCounter == 260)) ? 3'b111 : 3'b000;
				27: SOUT[2:0] <= ((BitCounter == 260) || (BitCounter == 261)) ? 3'b111 : 3'b000;
				28: SOUT[2:0] <= ((BitCounter == 261) || (BitCounter == 262)) ? 3'b111 : 3'b000;
				29: SOUT[2:0] <= ((BitCounter == 262) || (BitCounter == 263)) ? 3'b111 : 3'b000;
				30: SOUT[2:0] <= ((BitCounter == 263) || (BitCounter == 264)) ? 3'b111 : 3'b000;
				31: SOUT[2:0] <= ((BitCounter == 264) || (BitCounter == 265)) ? 3'b111 : 3'b000;
				32: SOUT[2:0] <= ((BitCounter == 265) || (BitCounter == 266)) ? 3'b111 : 3'b000;
				33: SOUT[2:0] <= ((BitCounter == 266) || (BitCounter == 267)) ? 3'b111 : 3'b000;
				34: SOUT[2:0] <= ((BitCounter == 267) || (BitCounter == 268)) ? 3'b111 : 3'b000;
				35: SOUT[2:0] <= ((BitCounter == 268) || (BitCounter == 269)) ? 3'b111 : 3'b000;
				36: SOUT[2:0] <= ((BitCounter == 269) || (BitCounter == 270)) ? 3'b111 : 3'b000;
				37: SOUT[2:0] <= ((BitCounter == 270) || (BitCounter == 271)) ? 3'b111 : 3'b000;
				38: SOUT[2:0] <= ((BitCounter == 271) || (BitCounter == 272)) ? 3'b111 : 3'b000;
				39: SOUT[2:0] <= ((BitCounter == 272) || (BitCounter == 273)) ? 3'b111 : 3'b000;
				40: SOUT[2:0] <= ((BitCounter == 273) || (BitCounter == 274)) ? 3'b111 : 3'b000;
				41: SOUT[2:0] <= ((BitCounter == 274) || (BitCounter == 275)) ? 3'b111 : 3'b000;
				42: SOUT[2:0] <= ((BitCounter == 275) || (BitCounter == 276)) ? 3'b111 : 3'b000;
				43: SOUT[2:0] <= ((BitCounter == 276) || (BitCounter == 277)) ? 3'b111 : 3'b000;
				44: SOUT[2:0] <= ((BitCounter == 277) || (BitCounter == 278)) ? 3'b111 : 3'b000;
				45: SOUT[2:0] <= ((BitCounter == 278) || (BitCounter == 279)) ? 3'b111 : 3'b000;
				46: SOUT[2:0] <= ((BitCounter == 279) || (BitCounter == 280)) ? 3'b111 : 3'b000;
				47: SOUT[2:0] <= ((BitCounter == 280) || (BitCounter == 281)) ? 3'b111 : 3'b000;
				48: SOUT[2:0] <= ((BitCounter == 281) || (BitCounter == 282)) ? 3'b111 : 3'b000;
				49: SOUT[2:0] <= ((BitCounter == 282) || (BitCounter == 283)) ? 3'b111 : 3'b000;
				50: SOUT[2:0] <= ((BitCounter == 283) || (BitCounter == 284)) ? 3'b111 : 3'b000;
				51: SOUT[2:0] <= ((BitCounter == 284) || (BitCounter == 285)) ? 3'b111 : 3'b000;
				52: SOUT[2:0] <= ((BitCounter == 285) || (BitCounter == 286)) ? 3'b111 : 3'b000;
				default:
					SOUT[2:0] <= 3'b000;
			endcase// case(GN)
			
		end	
// =================================
// ======= GCP Signal gen ==========
// =================================
			
			case(BitCounter)// these cases, after certain clock cycles, 
			//we need to generate short pulse for VFD in order to get proper PWM for each brightness level.
			72,// 1st pulse after 72 clock cycles.
			144,// 2nd pulse after 144 clock cycles.
			192,// 3rd pulse after 192 clock cycles.
			216,// 4th pulse after 216 clock cycles.
			240,// 5th pulse after 240 clock cycles.
			256:// 6th pulse after 256 clock cycles.
				GCP <= 1;
			//3 clock cycles later (250ns), put GCP pin down.
			75,
			147,
			195,
			219,
			243,
			259:
				GCP <= 0;
			default: GCP <= GCP;// retain same state
	
			endcase
			
		
	end
	
	3:begin// Done, idle.
		GRAM_CE <= 0;// Disable BRAM read.
		
		SOUT <= 3'b000;
		
		//reset counter to their original state.
		GN <= 1;// Always set grid to starting point (first grid).
		Mod6 <= 0;// reset the mod 6 counter.
		BitCounter <= 0;// reset bit counter to 0.
		clk_cnt39 <= 0;// reset row counter to 0.
				
	end
	
	endcase// main_fsm
	
end// check for SCS (Chip select of slave SPI controlled by host).
else begin

	GRAM_CE <= 0;// Disable BRAM read.
		
	//reset IO to default
	SOUT <= 3'b000;
	BLK_CTRL <= 1;
	LAT_CTRL <= 0;
	
	//reset counter to their original state.
	GN <= 1;// Always set grid to starting point (first grid).
	Mod6 <= 0;// reset the mod 6 counter.
	BitCounter <= 0;// reset bit counter to 0.
	clk_cnt39 <= 0;// reset row counter to 0.
	
	//reset fsm to their default.
	main_fsm <= 0;
	bram_fsm <= 0;
	
end

end

endmodule// top

// Pseudo C code for converting 8bit RGB into 3 bit Grayscale 00XXXYYY format.
/*
void imgto3(void *img8bit, ,size RGBsize, void *img3bit, size Graysize){
	uint8_t RChan, GChan, BChan, RGBMerge;
	
	// Conversion algorithm to map 0-255 to 0-7
	// lvl = (image8bit*7)/255;
	
	for(uint32_t i=0; i < RGBsize; i+= 3){
		// Parse each color brightness level and convert to 3 bit for each level 
		RChan = (*(img8bit + i) * 7) / 255;
		GChan = (*(image8bit + 1 + i) * 7)/ 255;
		BChan = (*(image8bit + 2 + i) * 7) / 255;
	
		// need the smarter Algorithm.
		RGBMerge = (RChan + GChan + BChan) / 3;// merge all color channel into 1
		
		// img3bit format is 00XXXYYY.
		// put RGBMerge data into the 3bit bytes
		*img3bit |= RGBMerge << ( i%2 ? 0 : 3);
		img3bit = i >> 2;// move to next byte after converted 2 pixels.
	}
}	
*/