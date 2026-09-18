# xsim run of rom_loader_tb: VHDL DUT (rom_loader.vhd) + SV bench + XPM CDC.
#   powershell -File run_rom_loader_tb.ps1
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$work   = Join-Path $core 'ooc\rom_loader_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" --work xpm "$vivado\data\ip\xpm\xpm_VCOMP.vhd" | Out-Null
& "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv" | Out-Null
& "$bin\xvhdl.bat" -2008 "$core\vhdl\rom_loader.vhd"
& "$bin\xvlog.bat" -sv "$here\rom_loader_tb.sv"
& "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null
& "$bin\xelab.bat" -L xpm -debug typical rom_loader_tb glbl -s rom_loader_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
& "$bin\xsim.bat" rom_loader_sim -R 2>&1 | Select-String -Pattern 'ERROR|FATAL|words delivered|register checks|RESULT|Time resolution' | ForEach-Object { $_.Line }

