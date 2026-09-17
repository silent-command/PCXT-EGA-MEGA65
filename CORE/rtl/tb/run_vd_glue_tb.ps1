# xsim run of vd_glue_tb: VHDL DUT (CORE/vhdl/vd_glue.vhd with the M2M vdrives package, XPM) + SV bench:
# the block buffer in both directions of the internal floppy drive's sector engine (docs/floppy.md).
#   powershell -File run_vd_glue_tb.ps1
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$m2m    = Resolve-Path (Join-Path $here '..\..\..\M2M')
$work   = Join-Path $core 'ooc\vd_glue_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" --work xpm "$vivado\data\ip\xpm\xpm_VCOMP.vhd" | Out-Null
& "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv" "$vivado\data\ip\xpm\xpm_memory\hdl\xpm_memory.sv" | Out-Null
# vdrives_pkg lives at the top of M2M/vhdl/vdrives.vhd (the entity below it needs the whole framework): copy the package out
$src = Get-Content "$m2m\vhdl\vdrives.vhd"
$start = ($src | Select-String -Pattern '^library ieee;' | Select-Object -First 1).LineNumber - 1
$end   = ($src | Select-String -Pattern '^end package' | Select-Object -First 1).LineNumber - 1
Set-Content -Path "$work\vdrives_pkg.vhd" -Value ($src[$start..$end] -join "`n")
& "$bin\xvhdl.bat" -2008 "$work\vdrives_pkg.vhd" "$core\vhdl\vd_glue.vhd" "$here\vd_glue_wrap.vhd"
if ($LASTEXITCODE -ne 0) { Write-Output "VDG RESULT: FAIL (DUT does not compile)"; exit 1 }
& "$bin\xvlog.bat" -sv "$here\vd_glue_tb.sv"
if ($LASTEXITCODE -ne 0) { Write-Output "VDG RESULT: FAIL (bench does not compile)"; exit 1 }
& "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null
& "$bin\xelab.bat" -L xpm -debug typical vd_glue_tb glbl -s vd_glue_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "VDG RESULT: FAIL (elaboration failed)"; exit 1 }
& "$bin\xsim.bat" vd_glue_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'VDG|ERROR|Error|Failure|FATAL' | ForEach-Object { $_.Line }
