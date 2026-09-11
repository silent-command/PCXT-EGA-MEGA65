# xsim run of analog_video_ctl_tb: CORE/vhdl/analog_video_ctl.vhd (analog VGA output policy, see
# docs/analog-video.md). No framework or XPM sources needed.
#   powershell -File run_analog_video_ctl_tb.ps1
# Full log: CORE/ooc/analog_video_ctl_tb/run.log
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$work   = Join-Path $core 'ooc\analog_video_ctl_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" -2008 "$core\vhdl\analog_video_ctl.vhd" "$here\analog_video_ctl_tb.vhd"
if ($LASTEXITCODE -ne 0) { Write-Output "AVC RESULT: FAIL (bench does not compile)"; exit 1 }
& "$bin\xelab.bat" -debug typical analog_video_ctl_tb -s analog_video_ctl_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "AVC RESULT: FAIL (elaboration failed)"; exit 1 }
& "$bin\xsim.bat" analog_video_ctl_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'AVC|ERROR|Error|Failure|FATAL' | ForEach-Object { $_.Line }
