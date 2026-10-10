# Define the primary clock on the Clk port
# Period: 0.5 ns (2 GHz), waveform rises at 0.0 ns and falls at 0.25 ns (50% duty cycle)
create_clock -period 0.28 -waveform {0.0 0.14} [get_ports CLK]

# Set input delay of 0.15 ns relative to Clk for all input ports
set_input_delay -clock CLK 0.15 [all_inputs]

# Set output delay of 0.15 ns relative to Clk for all output ports
set_output_delay -clock CLK 0.15 [all_outputs]
