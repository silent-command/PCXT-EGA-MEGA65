# xsim run of floppy_sector_engine_tb: VHDL DUT (CORE/vhdl/floppy_sector_engine.vhd with floppy_drive_if.vhd, floppy_mfm_writer.vhd
# and floppy_mfm_reader.vhd, XPM block RAM) against the SV drive model floppy_drive_model.sv: detect, seek,
# track capture at both rates, COPY into the block buffer, cache hits, motor timer, disk change, probe,
# no-disk timeouts (docs/floppy.md, phase 2).
#   powershell -File run_floppy_sector_engine_tb.ps1 [-Plus "FLPDBG FLPSTOP"]
#   (FLPDBG prints the cache-hit inputs of every command, FLPSTOP ends the run after the cache-hit test)
# Full log: CORE/ooc/floppy_sector_engine_tb/run.log  (about 6 s of simulated time)
param([string]$Plus = '')
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$work   = Join-Path $core 'ooc\floppy_sector_engine_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" --work xpm "$vivado\data\ip\xpm\xpm_VCOMP.vhd" | Out-Null
& "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv" "$vivado\data\ip\xpm\xpm_memory\hdl\xpm_memory.sv" | Out-Null
& "$bin\xvhdl.bat" -2008 "$core\vhdl\floppy_drive_if.vhd" "$core\vhdl\floppy_mfm_reader.vhd" "$core\vhdl\floppy_mfm_writer.vhd" "$core\vhdl\floppy_sector_engine.vhd"
if ($LASTEXITCODE -ne 0) { Write-Output "FLP RESULT: FAIL (DUT does not compile)"; exit 1 }
& "$bin\xvlog.bat" -sv "$here\floppy_drive_model.sv" "$here\floppy_sector_engine_tb.sv"
if ($LASTEXITCODE -ne 0) { Write-Output "FLP RESULT: FAIL (bench does not compile)"; exit 1 }
& "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null
& "$bin\xelab.bat" -L xpm -debug typical floppy_sector_engine_tb glbl -s floppy_sector_engine_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "FLP RESULT: FAIL (elaboration failed)"; exit 1 }
$plusargs = @()
foreach ($p in ($Plus -split ' ')) { if ($p -ne '') { $plusargs += @('-testplusarg', $p) } }
& "$bin\xsim.bat" floppy_sector_engine_sim -R @plusargs 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'FLP|ERROR|Error|Failure|FATAL' | ForEach-Object { $_.Line }
