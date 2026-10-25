# 1) 640x480 timing: 525 lines/frame, 307200 pixels/frame
# 2) audio chain: 20ms -> audio_valid ~= 960 (48kHz), acr_valid ~= 20
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent $here
$iv   = "D:\iverilog\bin\iverilog.exe"
$vvp  = "D:\iverilog\bin\vvp.exe"
$h    = "$src\user_source\hdl_source"

if (!(Test-Path $iv)) { Write-Error "iverilog not found: $iv" }

Write-Host "=== timing ==="
& $iv -g2012 -o "$here\tb_timing.out" -I "$h\SD" `
    "$here\tb_timing.v" `
    "$h\SD\video_timing_data.v" `
    "$h\SD\color_bar.v"
& $vvp "$here\tb_timing.out"

Write-Host "=== audio ==="
& $iv -g2012 -o "$here\tb_audio.out" `
    "$here\tb_audio.v" `
    "$h\audio\hdmi_audio_tone_i2s_64fs.v" `
    "$h\audio\I2S_receiver.v" `
    "$h\audio\audio_arc_calculate.v"
& $vvp "$here\tb_audio.out"

Write-Host "=== fb dual read (A/B lockstep) ==="
& $iv -g2012 -s tb_fb_dual -o "$here\tb_fb_dual.out" `
    "$here\tb_fb_dual.v" `
    "$here\sdram_bhv.v" `
    "$h\SD\frame_read_write_dual.v" `
    "$h\SD\frame_fifo_read_arb.v" `
    "$h\SD\frame_fifo_write.v" `
    "$h\SD\rd_arbiter.v" `
    "$h\ip\afifo_16_32_256.v" `
    "$h\ip\afifo_32_16_256.v"
& $vvp "$here\tb_fb_dual.out"

Write-Host "=== regs (16 keys / seg / 1Hz) ==="
& $iv -g2012 -s tb_regs -o "$here\tb_regs.out" `
    "$here\tb_regs.v" `
    "$h\control\regs.v"
& $vvp "$here\tb_regs.out"

Write-Host "=== M2 line read (A/B 1280 words) ==="
& $iv -g2012 -s tb_line_read -o "$here\tb_line_read.out" `
    "$here\tb_line_read.v" `
    "$h\video\frame_line_read.v"
& $vvp "$here\tb_line_read.out"

Write-Host "=== M2 mixer (dissolve / slide) ==="
& $iv -g2012 -s tb_mixer -o "$here\tb_mixer.out" `
    "$here\tb_mixer.v" `
    "$h\video\mixer.v"
& $vvp "$here\tb_mixer.out"

Write-Host "=== M2 disp_ctrl (progress / direct) ==="
& $iv -g2012 -s tb_disp_ctrl -o "$here\tb_disp_ctrl.out" `
    "$here\tb_disp_ctrl.v" `
    "$h\video\disp_ctrl.v"
& $vvp "$here\tb_disp_ctrl.out"

Write-Host "=== M2 line scheduler ==="
& $iv -g2012 -s tb_line_sched -o "$here\tb_line_sched.out" `
    "$here\tb_line_sched.v" `
    "$h\video\line_sched.v"
& $vvp "$here\tb_line_sched.out"

Write-Host "=== M2 line buffer (dual clock) ==="
& $iv -g2012 -s tb_line_buffer -o "$here\tb_line_buffer.out" `
    "$here\tb_line_buffer.v" `
    "$h\video\line_buffer.v"
& $vvp "$here\tb_line_buffer.out"

Write-Host "=== M2 video chain (line read + buffer + mixer) ==="
& $iv -g2012 -s tb_chain -I "$h\SD" -o "$here\tb_chain.out" `
    "$here\tb_chain.v" `
    "$h\SD\video_timing_data.v" `
    "$h\SD\color_bar.v" `
    "$h\video\video_pos.v" `
    "$h\video\line_sched.v" `
    "$h\video\disp_ctrl.v" `
    "$h\video\frame_line_read.v" `
    "$h\video\line_buffer.v" `
    "$h\video\mixer.v" `
    "$h\video\video_delay2.v"
& $vvp "$here\tb_chain.out"

Write-Host "=== sdram selftest ==="
& $iv -g2012 -s tb_selftest -o "$here\tb_selftest.out" `
    "$here\tb_selftest.v" `
    "$h\SD\sdram_selftest.v"
& $vvp "$here\tb_selftest.out"
