# run_fb.ps1 -- compile & run the framebuffer-building self-checks
#   [1/4] sdram_bhv   : write N words, read back, compare
#   [2/4] stub_source : dump its image to stub_frame.bmp
#   [3/4] fb_mgr(写侧) : stub -> SDRAM(WR1), then dump SDRAM to fb_frame.bmp
#   [4/4] fb_mgr(双缓冲): write + read + swap, verify frame switching & alignment
# Usage:  cd D:\fpga_2026\hdmi_test\sim ; .\run_fb.ps1
$ErrorActionPreference = "Continue"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$iver = "D:\iverilog\bin\iverilog.exe"
$vvp  = "D:\iverilog\bin\vvp.exe"

Push-Location $here
try {
    Write-Host "==> [1/4] sdram_bhv self-check"
    & $iver -g2012 -o tb_sdram_bhv.out ..\rtl\sdram_bhv.v tb_sdram_bhv.v
    if ($LASTEXITCODE -ne 0) { throw "compile failed (sdram_bhv)" }
    & $vvp tb_sdram_bhv.out
    if ($LASTEXITCODE -ne 0) { throw "run failed (sdram_bhv)" }

    Write-Host ""
    Write-Host "==> [2/4] stub_source BMP"
    & $iver -g2012 -o tb_stub.out ..\rtl\stub_source.v tb_stub.v
    if ($LASTEXITCODE -ne 0) { throw "compile failed (stub)" }
    & $vvp tb_stub.out
    if ($LASTEXITCODE -ne 0) { throw "run failed (stub)" }

    Write-Host ""
    Write-Host "==> [3/4] fb_mgr write side (stub -> SDRAM)"
    & $iver -g2012 -o tb_fb_write.out ..\rtl\sdram_bhv.v ..\rtl\stub_source.v ..\rtl\fb_mgr.v tb_fb_write.v
    if ($LASTEXITCODE -ne 0) { throw "compile failed (fb_write)" }
    & $vvp tb_fb_write.out
    if ($LASTEXITCODE -ne 0) { throw "run failed (fb_write)" }

    Write-Host ""
    Write-Host "==> [4/4] fb_mgr double-buffer (write + read + swap)"
    & $iver -g2012 -o tb_fb_dbuf.out ..\rtl\sdram_bhv.v ..\rtl\stub_source.v ..\rtl\fb_mgr.v ..\rtl\video_timing_720p.v tb_fb_dbuf.v
    if ($LASTEXITCODE -ne 0) { throw "compile failed (dbuf)" }
    & $vvp tb_fb_dbuf.out
    if ($LASTEXITCODE -ne 0) { throw "run failed (dbuf)" }

    Write-Host ""
    Write-Host "==> artifacts:"
    Get-ChildItem stub_frame.bmp, fb_frame.bmp -ErrorAction SilentlyContinue |
        ForEach-Object { "    {0}  ({1:N1} KB)" -f $_.Name, ($_.Length/1KB) }
    Write-Host "==> open the images:  stub_frame.bmp / fb_frame.bmp"
}
finally {
    Pop-Location
}
