# xsim run of ne1000_tb: the NE1000 card (CORE/rtl/ne1000.sv) on the MAC (CORE/vhdl/eth_mac.vhd,
# with the precompiled unisim library for the reference-clock ODDR), driven with the Crynwr NE1000
# packet driver's register sequences (8390.asm / ne1000.asm) and a KSZ8081 + RMII wire model.
#   powershell -File run_ne1000_tb.ps1
# Full log: CORE/ooc/ne1000_tb/run.log
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$work   = Join-Path $core 'ooc\ne1000_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" -2008 "$core\vhdl\eth_mac.vhd"
if ($LASTEXITCODE -ne 0) { Write-Output "NE1000 RESULT: FAIL (MAC does not compile)"; exit 1 }
& "$bin\xvlog.bat" -sv "$core\rtl\ne1000.sv" "$here\ne1000_tb.sv"
if ($LASTEXITCODE -ne 0) { Write-Output "NE1000 RESULT: FAIL (card or bench does not compile)"; exit 1 }
& "$bin\xelab.bat" -L unisim -debug typical ne1000_tb -s ne1000_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "NE1000 RESULT: FAIL (elaboration failed)"; exit 1 }
& "$bin\xsim.bat" ne1000_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'NE1000|CASE|ERROR|Error|Failure|FATAL' | ForEach-Object { $_.Line }
