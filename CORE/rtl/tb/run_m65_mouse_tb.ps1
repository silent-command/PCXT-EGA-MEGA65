# xsim run of m65_mouse_tb: VHDL DUT (CORE/vhdl/m65_mouse_ps2.vhd, MEGA65 joystick port -> PS/2 mouse
# device) with a behavioural PS/2 host model in the bench.
#   powershell -File run_m65_mouse_tb.ps1
# Full log: CORE/ooc/m65_mouse_tb/run.log
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$work   = Join-Path $core 'ooc\m65_mouse_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" -2008 "$core\vhdl\m65_mouse_ps2.vhd" "$here\m65_mouse_tb.vhd"
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }
& "$bin\xelab.bat" -debug typical m65_mouse_tb -s m65_mouse_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }
& "$bin\xsim.bat" m65_mouse_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'RESULT|FAIL|ERROR|Error|Failure|FATAL|aborted|bytes received' | ForEach-Object { $_.Line }
