# 运行两个快速验证：
#   1) 640×480 时序：525 行/帧、307200 像素/帧
#   2) 音频链路：20ms 内 audio_valid ≈ 960（48kHz）
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent $here
$iv   = "D:\iverilog\bin\iverilog.exe"
$vvp  = "D:\iverilog\bin\vvp.exe"

if (!(Test-Path $iv)) { Write-Error "找不到 iverilog: $iv" }

Write-Host "=== timing ==="
& $iv -g2012 -o "$here\tb_timing.out" -I "$src\user_source\hdl_source\SD" `
    "$here\tb_timing.v" `
    "$src\user_source\hdl_source\SD\video_timing_data.v" `
    "$src\user_source\hdl_source\SD\color_bar.v"
& $vvp "$here\tb_timing.out"

Write-Host "=== audio ==="
& $iv -g2012 -o "$here\tb_audio.out" `
    "$here\tb_audio.v" `
    "$src\user_source\hdl_source\hdmi_audio_tone_i2s_64fs.v" `
    "$src\user_source\hdl_source\I2S_receiver.v" `
    "$src\user_source\hdl_source\audio_arc_calculate.v"
& $vvp "$here\tb_audio.out"
