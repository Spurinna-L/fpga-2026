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
    "$h\video\video_delay2.v",
    "$h\video\video_pos.v",
    "$h\video\line_buffer.v",
    "$h\video\line_sched.v",
    "$h\video\frame_line_read.v",
    "$h\video\disp_ctrl.v",
    "$h\video\mixer.v",
    "$h\video\video_post.v",
    "$h\video\video_proc.v",
    "$h\video\video_param_latch.v",
    "$h\video\osd_composer.v",
    "$h\video\font_ascii_8x16.v",
    "$h\video\logo_overlay.v",
    "$h\video\logo_data_32x32.v",
    "$h\video\font_cn_16x16.v",
    "$h\video\scroll_text_overlay.v",
    "$h\hdmi\hdmi_phy_warpper.v",
    "$h\hdmi\lane_lvds_10_1.v",
    "$h\SD\ax_debounce.v",
    "$h\SD\bmp_read.v",
    "$h\SD\bmp_scale.v",
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
    "$h\SD\sdr_refresh_sweep.v",
    "$here\base_stubs.v"
)

& $iverilog -g2012 -D SIM_STUBS -s top -o "$here\base_syntax.out" -I "$h\SD" @files
if ($LASTEXITCODE -eq 0) {
    Write-Host "SYNTAX OK"
} else {
    Write-Error "SYNTAX FAILED ($LASTEXITCODE)"
}
