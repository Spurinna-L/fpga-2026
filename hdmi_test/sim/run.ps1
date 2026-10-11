# run.ps1 -- compile and run the 720p video-chain simulation
# Usage (PowerShell):
#   cd D:\fpga_2026\hdmi_test\sim
#   .\run.ps1
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$iver = "D:\iverilog\bin\iverilog.exe"
$vvp  = "D:\iverilog\bin\vvp.exe"

Push-Location $here
try {
    Write-Host "==> compiling ..."
    & $iver -g2012 -o sim.out `
        ..\rtl\video_timing_720p.v `
        ..\rtl\test_pattern.v `
        tb_video.v
    if ($LASTEXITCODE -ne 0) { throw "iverilog compile failed" }

    Write-Host "==> running simulation (detail) ..."
    & $vvp sim.out
    if ($LASTEXITCODE -ne 0) { throw "vvp run failed" }

    Write-Host "==> running simulation (frame view) ..."
    & $vvp sim.out +FRAME
    if ($LASTEXITCODE -ne 0) { throw "vvp frame run failed" }

    Write-Host "==> done. artifacts:"
    Get-ChildItem frame.bmp, wave_detail.vcd, wave_frame.vcd -ErrorAction SilentlyContinue |
        ForEach-Object { "    {0}  ({1:N1} KB)" -f $_.Name, ($_.Length/1KB) }
    Write-Host "==> image:  double-click frame.bmp"
    Write-Host "==> wave :  & 'D:\iverilog\bin\gtkwave.exe' wave_detail.vcd"
    Write-Host "           & 'D:\iverilog\bin\gtkwave.exe' wave_frame.vcd"
}
finally {
    Pop-Location
}
