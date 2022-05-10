# VFDHackICE  [W.I.P]

VFDHackICE is a upgrade version of VFDHack32 and took the Idea of VFDHack32_DB (daughter Board) to next level.  

Based on iCE40LP1K FPGA, on iCESugar nano board.

Dependencies 
=

0. make (If IIRC it's from build-essential)
1. Yosys
2. nextpnr-ice40
3. icepack
4. iverilog (optional).
5. your favorite choice of text editor.

Make
=

1. run ```make verify``` to verify with iverilog
2. run ```make``` to build the binary
3. drag and drop the main.bin file into the iCELink programmer (incase you use iCESugar nano like me).

Connection (refer to the io.pcf) WARNING : I/O is only 3v3 tolerance!
=

| LP1K FPGA | MN15439A VFD |
|-----------|--------------|
| A1        |      S1      |
| B1        |      S2      |
| C2        |      S3      |
| E1        |      CLK     |
| E3        |      BLK     |
| B5        |      LAT     |
| C6        |      GCP     |

| LP1K FPGA | CPU / HOST |
|-----------|------------|
| B3        |    MOSI    |
| A3        |     SCK    |
| C5        |     /CE    |

Host to FPGA SPI packet
=

total of 3003 bytes (implement 1 byte command system soon).  
```
(Byte0)(Byte1)(Byte2)....(Byte3002)  
```
Single Byte contain 2 pixels data.  
```
(MSB)(0)(0)(5:3)(2:0)(LSB) 
```
Since the MN15439A capable of 8 level Grayscale, It requires to use 3bit system (2^3 = 8, that make sense, right?).  
The data packat arrange in this format. 
```
(Byte0:00AAABBB)(Byte1:00CCCDDD)(Byte2:00EEEFFF)
```
and repeat itself for 1001 times.  
  
Normally, the MN15439 update display vertically each time, 6 pixels wide (abcdef) and 39 pixels tall.  
But when we send the 3 bit data, each bit split into 3 separated data line. That's why Tri-SPI PHY need to be implemented.  
Also the Dislpay accept the pixel data in this weird order " A F B E C D" instead of ABCDEF that we used to remember when we were young. 

Why FPGA?
=

The FPGA did all heavy-lifting tasks. Which ordinary microcontroller can do (can doesn't mean that it's great). FPGA offers the faster operation. So, I don't need to worry about the lack of speed.  
  
So these are HEAVY LIFTING tasks that FPGA need to do.  
1. working as Display Buffer.
2. act as SPI slave device.
3. generate Gradient Control Pulse (GCP) for MN15439A.
4. Split 3 bit pixel data into separated Serial Data wire (Tri-SPI PHY).
5. Display refreshing (52 times per 1 frame @ 60 fps). 

The most powerful MCU that I own (STM32F303) can do only 2 or 3 things at once, I ran into the problem that If I dedicate 2 SPI interface to 2 DMA controllers and 1 left for CPU to run. I won't be able to generate the GCP signal (Frequency change in realtime. AFAIK, there's no STM32 Timer that can do this). This limitation is real pure frustation. Even though I can use another STM8 to generate the GCP by feeding the SPI clock as reference input from STM32. but If that is gonna be complicated, Why don't I use FPGA.  
  
Actually, I have this idea of using FPGA since I know the existence of FPGA when I was Grade 10. But back then my flight hour is so little. But now 4 years later I've grown up, My C coding experience turn 6 years old. With tricks and methods I've use, finally my Verilog time has come! 
