# iverilog syntax check (encrypted PLL/SDRAM replaced by sim/base_stubs.v)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent $here
$iverilog = "D:\iverilog\bin\iverilog.exe"

if (!(Test-Path $iverilog)) {
    Write-Error "iverilog not found: $iverilog"
}

$h = "$src\user_source\hdl_source"
$files = @(
    "$h\top_tf_hdmi_audio.v",
    "$h\control\keyboard_scan.v",
    "$h\control\key_filter.v",
    "$h\control\regs.v",
    "$h\control\reset_sync.v",
    "$h\control\seg_led.v",
    "$h\control\seg_led_decoder.v",
    "$h\control\seg_sel_decoder.v",
    "$h\audio\I2S_receiver.v",
    "$h\audio\audio_arc_calculate.v",
    "$h\audio\hdmi_audio_tone_i2s_64fs.v",
    "$h\video\video_rgb_to_axis_640x480.v",
    "$h\video\test_pattern_640x480.v",
    "$h\hdmi\hdmi_phy_warpper.v",
    "$h\hdmi\lane_lvds_10_1.v",
    "$h\SD\ax_debounce.v",
    "$h\SD\bmp_read.v",
    "$h\SD\color_bar.v",
    "$h\SD\frame_fifo_read_arb.v",
    "$h\SD\frame_fifo_read.v",
    "$h\SD\frame_fifo_write.v",
    "$h\SD\frame_read_write.v",
    "$h\SD\frame_read_write_dual.v",
    "$h\SD\rd_arbiter.v",
    "$h\SD\sd_card_bmp.v",
    "$h\SD\video_delay.v",
    "$h\SD\video_timing_data.v",
    "$h\SD\sd_card_cmd.v",
    "$h\SD\sd_card_sec_read_write.v",
    "$h\SD\sd_card_top.v",
    "$h\SD\spi_master.v",
    "$h\SD\sdram_selftest.v",
    "$here\base_stubs.v"
)

& $iverilog -g2012 -s top -o "$here\base_syntax.out" -I "$h\SD" @files
if ($LASTEXITCODE -eq 0) {
    Write-Host "SYNTAX OK"
} else {
    Write-Error "SYNTAX FAILED ($LASTEXITCODE)"
}
