# iverilog 语法检查（不含加密核/PLL/SDRAM，使用 base_stubs.v 空壳）
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent $here
$iverilog = "D:\iverilog\bin\iverilog.exe"

if (!(Test-Path $iverilog)) {
    Write-Error "找不到 iverilog: $iverilog"
}

$files = @(
    "$src\user_source\hdl_source\top_tf_hdmi_audio.v",
    "$src\user_source\hdl_source\keyboard_scan.v",
    "$src\user_source\hdl_source\key_filter.v",
    "$src\user_source\hdl_source\seg_led.v",
    "$src\user_source\hdl_source\seg_led_decoder.v",
    "$src\user_source\hdl_source\seg_sel_decoder.v",
    "$src\user_source\hdl_source\I2S_receiver.v",
    "$src\user_source\hdl_source\audio_arc_calculate.v",
    "$src\user_source\hdl_source\hdmi_audio_tone_i2s_64fs.v",
    "$src\user_source\hdl_source\video_rgb_to_axis_640x480.v",
    "$src\user_source\hdl_source\test_pattern_640x480.v",
    "$src\user_source\hdl_source\hdmi_phy_warpper.v",
    "$src\user_source\hdl_source\lane_lvds_10_1.v",
    "$src\user_source\hdl_source\SD\ax_debounce.v",
    "$src\user_source\hdl_source\SD\bmp_read.v",
    "$src\user_source\hdl_source\SD\color_bar.v",
    "$src\user_source\hdl_source\SD\frame_fifo_read.v",
    "$src\user_source\hdl_source\SD\frame_fifo_write.v",
    "$src\user_source\hdl_source\SD\frame_read_write.v",
    "$src\user_source\hdl_source\SD\sd_card_bmp.v",
    "$src\user_source\hdl_source\SD\video_delay.v",
    "$src\user_source\hdl_source\SD\video_timing_data.v",
    "$src\user_source\hdl_source\SD\sd_card_cmd.v",
    "$src\user_source\hdl_source\SD\sd_card_sec_read_write.v",
    "$src\user_source\hdl_source\SD\sd_card_top.v",
    "$src\user_source\hdl_source\SD\spi_master.v",
    "$here\base_stubs.v"
)

& $iverilog -g2012 -s top -o "$here\base_syntax.out" -I "$src\user_source\hdl_source\SD" @files
if ($LASTEXITCODE -eq 0) {
    Write-Host "SYNTAX OK"
} else {
    Write-Error "SYNTAX FAILED ($LASTEXITCODE)"
}
