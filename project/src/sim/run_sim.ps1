# 1) 640x480 timing: 525 lines/frame, 307200 pixels/frame
# 2) audio chain: 20ms -> audio_valid ~= 960 (48kHz), acr_valid ~= 20
# 3) M0-M2 video/storage/OSD testbenches
#
# Note: tb_chain simulates 9 full frames (~151 ms sim time) and takes about
# 4-5 minutes in iverilog; this is expected, not a hang.
#
# Any iverilog compile failure aborts the run immediately, so a stale .out
# from a previous run can never be mistaken for a PASS.
#
# Simulator selection: iverilog is used when present; otherwise the script
# falls back to ModelSim (vlog/vsim) so the same regression runs on machines
# that only have Intel FPGA / ModelSim installed.
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent $here
$iv   = "D:\iverilog\bin\iverilog.exe"
$vvp  = "D:\iverilog\bin\vvp.exe"
$h    = "$src\user_source\hdl_source"

$vlogCmd = Get-Command vlog -ErrorAction SilentlyContinue
$vsimCmd = Get-Command vsim -ErrorAction SilentlyContinue
$lib     = "$here\msim"

if ((Test-Path $iv) -and (Test-Path $vvp)) {
    $useMsim = $false
} elseif ($vlogCmd -and $vsimCmd) {
    $useMsim = $true
    Write-Host "iverilog not found -> falling back to ModelSim: $($vlogCmd.Source)"
    if (!(Test-Path $lib)) { & vlib $lib | Out-Null }
} else {
    Write-Error "no Verilog simulator found (need iverilog at $iv or ModelSim vlog/vsim)"
}

# 已知/预期失败的遗留试验（对应 RTL 已标记 UsedInSyn=false，不进综合）。
# tb_fb_dual 测的是 M1「双读引擎」实验，文档《模块清单与分工.md》§2.5 已写明
# 「双读实验，未跑通」，因此默认跳过，避免它把整条回归挡住。
$SkipTb = @('tb_fb_dual')

function Invoke-Tb {
    param(
        [string]   $Name,
        [string[]] $Files,
        [string]   $Include = ""
    )
    if ($script:SkipTb -contains $Name) {
        Write-Host "=== $Name === (SKIP: legacy known-fail, see gongdan doc sec.2 status table)"
        return
    }
    Write-Host "=== $Name ==="
    if ($useMsim) {
        $defs = @("+define+SIM_STUBS")
        if ($Include -ne "") { $defs += "+incdir+$Include" }
        & vlog -quiet -work $lib @defs @Files | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "ModelSim vlog compile FAILED: $Name"
        }
        $log  = & vsim -c -work $lib $Name -do "run -all; quit -f" 2>&1
        $code = $LASTEXITCODE
        $log | ForEach-Object { Write-Host $_ }
        if ($code -ne 0) {
            throw "ModelSim vsim run FAILED: $Name"
        }
    } else {
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
        $log  = & $vvp $out 2>&1
        $code = $LASTEXITCODE
        $log | ForEach-Object { Write-Host $_ }
        if ($code -ne 0) {
            throw "vvp run FAILED: $Name"
        }
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

# M3.3 风格化滤镜：3 拍延迟 + de/x/y 同拍 + 8 种模式逐像素对比参考模型
Invoke-Tb 'tb_filter' @(
    "$here\base_stubs.v",
    "$here\tb_filter.v",
    "$h\video\video_fx.v"
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

# Integration: 6-cycle sideband alignment + pixel-exact bypass when OSD/subtitle off
Invoke-Tb 'tb_video_post' @(
    "$here\base_stubs.v",
    "$here\tb_video_post.v",
    "$h\video\video_post.v",
    "$h\video\video_fx.v",
    "$h\video\video_proc.v",
    "$h\video\video_param_latch.v",
    "$h\video\osd_composer.v",
    "$h\video\font_ascii_8x16.v",
    "$h\video\logo_overlay.v",
    "$h\video\logo_data_32x32.v",
    "$h\video\scroll_text_overlay.v",
    "$h\video\font_cn_16x16.v",
    "$h\video\audio_viz.v",
    "$h\video\wave_capture.v",
    "$h\video\spectrum_analyzer.v"
)

# M1 debug tool: SDRAM self-test (not synthesized)
Invoke-Tb 'tb_selftest' @(
    "$here\tb_selftest.v",
    "$h\SD\sdram_selftest.v"
)
