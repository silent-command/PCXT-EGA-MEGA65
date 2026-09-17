# xsim run of floppy_phy_spike_tb: VHDL DUT (CORE/vhdl/floppy_phy_spike.vhd, MEGA65 R6 internal floppy
# drive spike: drive control sequencer, MFM reader with IDAM/DAM CRC check, status words) against an SV
# model of a 3.5" PC drive playing a synthetic System 34 track at both rates with speed error and jitter.
#   powershell -File run_floppy_phy_spike_tb.ps1
# Full log: CORE/ooc/floppy_phy_spike_tb/run.log  (about 3 s of simulated time)
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$work   = Join-Path $core 'ooc\floppy_phy_spike_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" -2008 "$core\vhdl\floppy_phy_spike.vhd"
if ($LASTEXITCODE -ne 0) { Write-Output "FLP RESULT: FAIL (DUT does not compile)"; exit 1 }
& "$bin\xvlog.bat" -sv "$here\floppy_phy_spike_tb.sv"
if ($LASTEXITCODE -ne 0) { Write-Output "FLP RESULT: FAIL (bench does not compile)"; exit 1 }
& "$bin\xelab.bat" -debug typical floppy_phy_spike_tb -s floppy_phy_spike_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "FLP RESULT: FAIL (elaboration failed)"; exit 1 }
& "$bin\xsim.bat" floppy_phy_spike_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'FLP|ERROR|Error|Failure|FATAL' | ForEach-Object { $_.Line }
