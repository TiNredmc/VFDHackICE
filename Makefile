# Make file to compile from the Verilog into Binary ready to flash.

source_file = main
pcf_file = io.pcf

build:
	yosys -g -p "synth_ice40 -json $(source_file).json -blif $(source_file).blif" $(source_file).v
	nextpnr-ice40 --lp1k --package cm36 --json $(source_file).json --pcf $(pcf_file) --asc $(source_file).asc --freq 12
	icepack $(source_file).asc $(source_file).bin

clean:
	rm -rf $(source_file).blif $(source_file).asc $(source_file).bin

verify:
	iverilog -D VCD_OUTPUT=/usr/local/share/yosys/ice40/cells_sim.v main.v
