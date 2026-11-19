## Clock Signal (L17 measures ~100 MHz on this board; must match CLK_HZ in nollama_top.v)
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 10.000 -name clk -waveform {0.000 5.000} -add [get_ports clk]

## Configuration: boot from the 4 MB Quad-SPI flash (x4, 33 MHz, compressed)
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

## Reset Button (BTN0 on Cmod A7 is pin A18; Active-HIGH)
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports reset_btn]

## Status LED (LED1)
set_property -dict {PACKAGE_PIN A17 IOSTANDARD LVCMOS33} [get_ports activity_led]

## Heartbeat LED (LED2) - clock-frequency check
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports heartbeat_led]

## Waveform select button (BTN1)
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports wave_btn]

## Pmod AMP2 on header JA (top row: JA1 = AIN, JA2 = GAIN, JA4 = ~SHUTDOWN)
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports amp_ain]
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} [get_ports amp_gain]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports amp_shutdown_n]

## MIDI Out to On-Board USB-UART (Streams MIDI directly to PC over USB cable)
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports midi_tx]

## =========================================================================
## Roland K-25M GPIO Connections
## =========================================================================

## COLA (Top / Break Switch Column Outputs)
set_property -dict {PACKAGE_PIN M3 IOSTANDARD LVCMOS33} [get_ports {cola[0]}]
#set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports {cola[1]}]  ;#
set_property -dict {PACKAGE_PIN L1 IOSTANDARD LVCMOS33} [get_ports {cola[1]}]
#set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33} [get_ports {cola[1]}]  ;# red
#set_property -dict {PACKAGE_PIN L1 IOSTANDARD LVCMOS33} [get_ports {cola[2]}]  ;# gray
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33} [get_ports {cola[2]}]
#set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33} [get_ports {cola[3]}]  ;# white
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports {cola[3]}]

## COLB (Bottom / Make Switch Column Outputs)
set_property -dict {PACKAGE_PIN L3 IOSTANDARD LVCMOS33} [get_ports {colb[0]}]
#set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33} [get_ports {colb[1]}]  ;#
set_property -dict {PACKAGE_PIN N3 IOSTANDARD LVCMOS33} [get_ports {colb[1]}]
#set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports {colb[1]}]  ;# yellow
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33} [get_ports {colb[2]}]
#set_property -dict {PACKAGE_PIN L2 IOSTANDARD LVCMOS33} [get_ports {colb[2]}]  ;# green
set_property -dict {PACKAGE_PIN L2 IOSTANDARD LVCMOS33} [get_ports {colb[3]}]
#set_property -dict {PACKAGE_PIN N3 IOSTANDARD LVCMOS33} [get_ports {colb[3]}]  ;# blue

## Shared 8 Row Sense Lines (Inputs with internal Pull-Downs)
set_property PACKAGE_PIN A16 [get_ports {row[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[0]}]
set_property PULLTYPE PULLDOWN [get_ports {row[0]}]
set_property PACKAGE_PIN K3 [get_ports {row[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[1]}]
set_property PULLTYPE PULLDOWN [get_ports {row[1]}]
set_property PACKAGE_PIN C15 [get_ports {row[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[2]}]
set_property PULLTYPE PULLDOWN [get_ports {row[2]}]
set_property PACKAGE_PIN H1 [get_ports {row[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[3]}]
set_property PULLTYPE PULLDOWN [get_ports {row[3]}]
set_property PACKAGE_PIN A15 [get_ports {row[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[4]}]
set_property PULLTYPE PULLDOWN [get_ports {row[4]}]
set_property PACKAGE_PIN B15 [get_ports {row[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[5]}]
set_property PULLTYPE PULLDOWN [get_ports {row[5]}]
set_property PACKAGE_PIN A14 [get_ports {row[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[6]}]
set_property PULLTYPE PULLDOWN [get_ports {row[6]}]
set_property PACKAGE_PIN J3 [get_ports {row[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {row[7]}]
set_property PULLTYPE PULLDOWN [get_ports {row[7]}]



## ILA must run on a free-running clock. For the decimated window (25 us/sample -> 8192 samples = ~204.8 ms;
## see ILA_RATE_HZ in nollama_top.v) set Capture Mode = BASIC with capture condition dbg_ila_ce == 1.


#set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 4 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER true [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 8192 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL true [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list clk_IBUF_BUFG]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 2 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {dbg_tx_state[0]} {dbg_tx_state[1]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 4 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {dbg_colb[0]} {dbg_colb[1]} {dbg_colb[2]} {dbg_colb[3]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 2 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list {dbg_wave_sel[0]} {dbg_wave_sel[1]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 7 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list {dbg_last_velocity[0]} {dbg_last_velocity[1]} {dbg_last_velocity[2]} {dbg_last_velocity[3]} {dbg_last_velocity[4]} {dbg_last_velocity[5]} {dbg_last_velocity[6]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 5 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list {dbg_fifo_count[0]} {dbg_fifo_count[1]} {dbg_fifo_count[2]} {dbg_fifo_count[3]} {dbg_fifo_count[4]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 12 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list {dbg_key0_timer[0]} {dbg_key0_timer[1]} {dbg_key0_timer[2]} {dbg_key0_timer[3]} {dbg_key0_timer[4]} {dbg_key0_timer[5]} {dbg_key0_timer[6]} {dbg_key0_timer[7]} {dbg_key0_timer[8]} {dbg_key0_timer[9]} {dbg_key0_timer[10]} {dbg_key0_timer[11]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe6]
set_property port_width 5 [get_debug_ports u_ila_0/probe6]
connect_debug_port u_ila_0/probe6 [get_nets [list {dbg_last_struck_key[0]} {dbg_last_struck_key[1]} {dbg_last_struck_key[2]} {dbg_last_struck_key[3]} {dbg_last_struck_key[4]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe7]
set_property port_width 4 [get_debug_ports u_ila_0/probe7]
connect_debug_port u_ila_0/probe7 [get_nets [list {dbg_cola[0]} {dbg_cola[1]} {dbg_cola[2]} {dbg_cola[3]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe8]
set_property port_width 16 [get_debug_ports u_ila_0/probe8]
connect_debug_port u_ila_0/probe8 [get_nets [list {dbg_synth_sample[0]} {dbg_synth_sample[1]} {dbg_synth_sample[2]} {dbg_synth_sample[3]} {dbg_synth_sample[4]} {dbg_synth_sample[5]} {dbg_synth_sample[6]} {dbg_synth_sample[7]} {dbg_synth_sample[8]} {dbg_synth_sample[9]} {dbg_synth_sample[10]} {dbg_synth_sample[11]} {dbg_synth_sample[12]} {dbg_synth_sample[13]} {dbg_synth_sample[14]} {dbg_synth_sample[15]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe9]
set_property port_width 3 [get_debug_ports u_ila_0/probe9]
connect_debug_port u_ila_0/probe9 [get_nets [list {dbg_scan_phase[0]} {dbg_scan_phase[1]} {dbg_scan_phase[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe10]
set_property port_width 3 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list {dbg_key0_state[0]} {dbg_key0_state[1]} {dbg_key0_state[2]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe11]
set_property port_width 8 [get_debug_ports u_ila_0/probe11]
connect_debug_port u_ila_0/probe11 [get_nets [list {dbg_top_sample[0]} {dbg_top_sample[1]} {dbg_top_sample[2]} {dbg_top_sample[3]} {dbg_top_sample[4]} {dbg_top_sample[5]} {dbg_top_sample[6]} {dbg_top_sample[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe12]
set_property port_width 2 [get_debug_ports u_ila_0/probe12]
connect_debug_port u_ila_0/probe12 [get_nets [list {dbg_active_col[0]} {dbg_active_col[1]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe13]
set_property port_width 8 [get_debug_ports u_ila_0/probe13]
connect_debug_port u_ila_0/probe13 [get_nets [list {dbg_row[0]} {dbg_row[1]} {dbg_row[2]} {dbg_row[3]} {dbg_row[4]} {dbg_row[5]} {dbg_row[6]} {dbg_row[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe14]
set_property port_width 1 [get_debug_ports u_ila_0/probe14]
connect_debug_port u_ila_0/probe14 [get_nets [list dbg_activity_led]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe15]
set_property port_width 1 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list dbg_fifo_is_note_on]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe16]
set_property port_width 1 [get_debug_ports u_ila_0/probe16]
connect_debug_port u_ila_0/probe16 [get_nets [list dbg_fifo_wr_en]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe17]
set_property port_width 1 [get_debug_ports u_ila_0/probe17]
connect_debug_port u_ila_0/probe17 [get_nets [list dbg_ila_ce]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe18]
set_property port_width 1 [get_debug_ports u_ila_0/probe18]
connect_debug_port u_ila_0/probe18 [get_nets [list dbg_midi_tx]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe19]
set_property port_width 1 [get_debug_ports u_ila_0/probe19]
connect_debug_port u_ila_0/probe19 [get_nets [list dbg_synth_ce]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk_IBUF_BUFG]
