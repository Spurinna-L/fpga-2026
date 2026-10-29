# 1) 640x480 timing: 525 lines/frame, 307200 pixels/frame
# 2) audio chain: 20ms -> audio_valid ~= 960 (48kHz), acr_valid ~= 20
# 3) M0-M2 video/storage/OSD testbenches
#
# Note: tb_chain simulates 9 full frames (~151 ms sim time) and takes about
# 4-5 minutes in iverilog; this is expected, not a hang.
#
# Any iverilog compile failure aborts the run immediately, so a stale .out
# from a previous run can never be mistaken for a PASS.
param([switch]$Full)   # -Full: 额外跑大尺寸缩放遍历（tb_scale_fast，约 10 分钟）
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent $here
$iv   = "D:\iverilog\bin\iverilog.exe"
$vvp  = "D:\iverilog\bin\vvp.exe"
$h    = "$src\user_source\hdl_source"

if (!(Test-Path $iv)) { Write-Error "iverilog not found: $iv" }

function Invoke-Tb {
    param(
        [string]   $Name,
        [string[]] $Files,
        [string]   $Include = ""
    )
    Write-Host "=== $Name ==="
    $out = "$here\$Name.out"
    Remove-Item $out -ErrorAction SilentlyContinue
    if ($Include -ne "") {
        & $iv -g2012 -D SIM_STUBS -I $Include -s $Name -o $out @Files
    } else {
        & $iv -g2012 -D SIM_STUBS -s $Name -o $out @Files
    }
    if ($LASTEXITCODE -ne 0) {
        throw "iverilog compile FAILED: $Name"
    }
    $log = & $vvp $out 2>&1
    $code = $LASTEXITCODE
    $log | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) {
        throw "vvp run FAILED: $Name"
    }
    $text = ($log | Out-String)
    if (($text -match 'FAIL') -or ($text -match 'TIMEOUT') -or ($text -match '(?m)^ERR ')) {
        throw "testbench reported FAIL: $Name"
    }
}

Invoke-Tb 'tb_timing' @(
    "$here\tb_timing.v",
    "$h\SD\video_timing_data.v",
    "$h\SD\color_bar.v"
) "$h\SD"

Invoke-Tb 'tb_audio' @(
    "$here\tb_audio.v",
    "$h\audio\hdmi_audio_tone_i2s_64fs.v",
    "$h\audio\I2S_receiver.v",
    "$h\audio\audio_arc_calculate.v"
)

# M1 reference: dual-read engine (not synthesized)
Invoke-Tb 'tb_fb_dual' @(
    "$here\tb_fb_dual.v",
    "$here\sdram_bhv.v",
    "$h\SD\frame_read_write_dual.v",
    "$h\SD\frame_fifo_read_arb.v",
    "$h\SD\frame_fifo_write.v",
    "$h\SD\rd_arbiter.v",
    "$h\ip\afifo_16_32_256.v",
    "$h\ip\afifo_32_16_256.v"
)

Invoke-Tb 'tb_regs' @(
    "$here\tb_regs.v",
    "$h\control\regs.v"
)

Invoke-Tb 'tb_bmp_read' @(
    "$here\tb_bmp_read.v",
    "$h\SD\bmp_read.v"
)

Invoke-Tb 'tb_bmp_scale' @(
    "$here\tb_bmp_scale.v",
    "$here\base_stubs.v",
    "$h\SD\bmp_scale.v",
    "$h\video\line_buffer.v"
)

Invoke-Tb 'tb_bmp_pipeline' @(
    "$here\tb_bmp_pipeline.v",
    "$here\base_stubs.v",
    "$h\SD\bmp_read.v",
    "$h\SD\bmp_scale.v",
    "$h\video\line_buffer.v"
)

# 用真实 SD 镜像回放 sd_card_bmp 全流程（镜像不存在时自动跳过）
$m3img = "$here\..\..\out\sd_card_m3_a.img"
if (Test-Path $m3img) {
    Invoke-Tb 'tb_sd_bmp' @(
        "$here\tb_sd_bmp.v",
        "$here\base_stubs.v",
        "$h\SD\sd_card_bmp.v",
        "$h\SD\bmp_read.v",
        "$h\SD\bmp_scale.v",
        "$h\SD\sd_card_top.v",
        "$h\SD\sd_card_sec_read_write.v",
        "$h\SD\sd_card_cmd.v",
        "$h\SD\spi_master.v",
        "$h\video\line_buffer.v"
    )
} else {
    Write-Host "SKIP tb_sd_bmp (需要 project/out/sd_card_m3_a.img)"
}

if ($Full) {
    Invoke-Tb 'tb_scale_fast' @(
        "$here\tb_scale_fast.v",
        "$here\base_stubs.v",
        "$h\SD\bmp_scale.v",
        "$h\video\line_buffer.v"
    )
}

Invoke-Tb 'tb_line_read' @(
    "$here\tb_line_read.v",
    "$h\video\frame_line_read.v"
)

Invoke-Tb 'tb_mixer' @(
    "$here\tb_mixer.v",
    "$h\video\mixer.v"
)

Invoke-Tb 'tb_disp_ctrl' @(
    "$here\tb_disp_ctrl.v",
    "$h\video\disp_ctrl.v"
)

Invoke-Tb 'tb_line_sched' @(
    "$here\tb_line_sched.v",
    "$h\video\line_sched.v"
)

# line buffer / chain need the EG_LOGIC_BRAM model from base_stubs (-D SIM_STUBS)
Invoke-Tb 'tb_line_buffer' @(
    "$here\tb_line_buffer.v",
    "$here\base_stubs.v",
    "$h\video\line_buffer.v"
)

Invoke-Tb 'tb_chain' @(
    "$here\tb_chain.v",
    "$here\base_stubs.v",
    "$h\SD\video_timing_data.v",
    "$h\SD\color_bar.v",
    "$h\video\video_pos.v",
    "$h\video\line_sched.v",
    "$h\video\disp_ctrl.v",
    "$h\video\frame_line_read.v",
    "$h\video\line_buffer.v",
    "$h\video\mixer.v",
    "$h\video\video_delay2.v"
) "$h\SD"

Invoke-Tb 'tb_video_proc' @(
    "$here\tb_video_proc.v",
    "$h\video\video_proc.v"
)

Invoke-Tb 'tb_param_latch' @(
    "$here\tb_param_latch.v",
    "$h\video\video_param_latch.v"
)

Invoke-Tb 'tb_osd' @(
    "$here\tb_osd.v",
    "$h\video\osd_composer.v",
    "$h\video\font_ascii_8x16.v"
)

Invoke-Tb 'tb_logo_overlay' @(
    "$here\tb_logo_overlay.v",
    "$h\video\logo_overlay.v",
    "$h\video\logo_data_32x32.v"
)

# M2 subtitle: font ROM lookup + frame-boundary scroll + bypass
Invoke-Tb 'tb_scroll_text' @(
    "$here\tb_scroll_text.v",
    "$h\video\scroll_text_overlay.v",
    "$h\video\font_cn_16x16.v"
)

# Integration: 2-cycle sideband alignment + pixel-exact bypass when OSD/subtitle off
Invoke-Tb 'tb_video_post' @(
    "$here\tb_video_post.v",
    "$h\video\video_post.v",
    "$h\video\video_proc.v",
    "$h\video\video_param_latch.v",
    "$h\video\osd_composer.v",
    "$h\video\font_ascii_8x16.v",
    "$h\video\logo_overlay.v",
    "$h\video\logo_data_32x32.v",
    "$h\video\scroll_text_overlay.v",
    "$h\video\font_cn_16x16.v"
)

# M1 debug tool: SDRAM self-test (not synthesized)
Invoke-Tb 'tb_selftest' @(
    "$here\tb_selftest.v",
    "$h\SD\sdram_selftest.v"
)
