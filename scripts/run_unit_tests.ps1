# -----------------------------------------------------------------------------
# run_unit_tests.ps1 -- fast standalone checks, no Xilinx IP required
#
#   .\scripts\run_unit_tests.ps1
#
# Runs in seconds because none of these DUTs instantiate xfft. These are the
# tests that actually prove correctness of the pieces that were wrong:
#   1. angle_fft4_par  -- the LIVE module (radar_dsp_3d_top.sv instantiates
#                         this one). Is it really a DFT, does it round/clamp
#                         correctly at the boundary, does it honor backpressure?
#   2. angle_fft4      -- the superseded serial/ping-pong variant. Kept only
#                         as a reference cross-check; nothing in the current
#                         top level instantiates it. FAILURE HERE DOES NOT
#                         BLOCK THE BUILD -- see $ok2 handling below.
#   3. ctm_transpose   -- does the corner turn actually transpose?
#
# FIXED 2 Sep: this runner's test #1 pointed at angle_fft4.sv, which is NOT
# the module radar_dsp_3d_top.sv instantiates (that's angle_fft4_par.sv).
# A clean PASS here was proving nothing about the live pipeline. Test #1 now
# targets the live module; the old test is demoted to non-blocking reference.
#
# Requires vivado/bin on PATH:
#   $env:Path += ";C:\Xilinx\2025.1\Vivado\bin"
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$work = Join-Path $root "build\unit_sim"
New-Item -ItemType Directory -Force -Path $work | Out-Null
Set-Location $work

function Run-Test($name, $srcs, $top) {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " $name" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    $full = $srcs | ForEach-Object { Join-Path $root $_ }
    & xvlog -sv @full 2>&1 | Select-String -Pattern "ERROR|error:" -Context 0,2
    if ($LASTEXITCODE -ne 0) { Write-Host "xvlog FAILED" -ForegroundColor Red; return $false }

    & xelab -debug typical $top -s "${top}_snap" 2>&1 | Select-String -Pattern "ERROR|error:"
    if ($LASTEXITCODE -ne 0) { Write-Host "xelab FAILED" -ForegroundColor Red; return $false }

    $out = & xsim "${top}_snap" -R 2>&1
    $out | Where-Object { $_ -match "TEST|FAIL|RESULT|checks:|beats checked|X =|cube" }

    if ($out -match "RESULT: PASS") { return $true } else { return $false }
}

$ok1 = Run-Test "ANGLE FFT -- LIVE module (angle_fft4_par, combinational)" `
                @("rtl\angle_fft4_par.sv", "tb\tb_angle_fft4_par.sv") `
                "tb_angle_fft4_par"

$ok2 = Run-Test "CORNER TURN (transpose ordering + backpressure)" `
                @("rtl\ctm_stub.sv", "tb\tb_ctm_transpose.sv") `
                "tb_ctm_transpose"

$ok3 = Run-Test "ANGLE FFT -- reference only, superseded serial variant (non-blocking)" `
                @("rtl\angle_fft4.sv", "tb\tb_angle_fft4.sv") `
                "tb_angle_fft4"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Yellow
if ($ok1) { Write-Host " angle_fft4_par (LIVE)     : PASS" -ForegroundColor Green }
else      { Write-Host " angle_fft4_par (LIVE)     : FAIL" -ForegroundColor Red }
if ($ok2) { Write-Host " ctm_transpose             : PASS" -ForegroundColor Green }
else      { Write-Host " ctm_transpose             : FAIL" -ForegroundColor Red }
if ($ok3) { Write-Host " angle_fft4 (reference)    : PASS" -ForegroundColor Green }
else      { Write-Host " angle_fft4 (reference)    : FAIL (non-blocking, not in top level)" -ForegroundColor DarkYellow }
Write-Host "==================================================" -ForegroundColor Yellow

Set-Location $root
# ok3 (the superseded serial reference) does NOT gate pass/fail -- only the
# two modules actually instantiated in radar_dsp_3d_top.sv do.
if ($ok1 -and $ok2) { exit 0 } else { exit 1 }
