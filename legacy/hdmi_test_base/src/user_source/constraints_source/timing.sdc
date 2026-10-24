# ============================================================
# timing.sdc - base path (TF BMP + HDMI 1.4b audio)
# ------------------------------------------------------------
# Board clock: 50 MHz (R7)
# PLLs:
#   u_sys_pll   : 100M (sd) / 125M (mem) / 125M_180
#   u_video_pll : 25M (pixel) / 125M (serial)
#   u_audio_pll : 12.288M (audio)
# ============================================================

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

derive_clocks

# Rename PLL outputs (if a path does not match, use the actual
# path shown in Timing Analyzer).
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_sys_pll/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_sys_pll/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# Pixel and serial clocks are mutually exclusive in the HDMI PHY.
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# Audio I2S is generated in audio_mclk and sampled in video_clk.
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {video_clk} hdmi_5x_clk sd_card_clk ext_mem_clk]

# If the report shows many false cross-domain violations between
# sd_card_clk / ext_mem_clk / video_clk (all handled by FIFOs),
# uncomment the group below after confirming the CDC paths.
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]
