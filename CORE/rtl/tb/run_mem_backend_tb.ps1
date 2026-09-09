# xsim run of mem_backend_tb: VHDL DUT (mem_backend.vhd) + M2M avm_fifo/avm_cache/avm_memory + XPM.
#   powershell -File run_mem_backend_tb.ps1
# Full log: CORE/ooc/mem_backend_tb/run.log
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$m2m    = Resolve-Path (Join-Path $core '..\M2M\vhdl\memory')
$work   = Join-Path $core 'ooc\mem_backend_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" --work xpm "$vivado\data\ip\xpm\xpm_VCOMP.vhd" | Out-Null
& "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv" | Out-Null
& "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_memory\hdl\xpm_memory.sv" | Out-Null
& "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_fifo\hdl\xpm_fifo.sv" | Out-Null
& "$bin\xvhdl.bat" -2008 "$m2m\axi_fifo.vhd" "$m2m\avm_fifo.vhd" "$m2m\avm_cache.vhd" "$m2m\avm_memory.vhd"
& "$bin\xvhdl.bat" -2008 "$core\vhdl\mem_backend.vhd"
& "$bin\xvhdl.bat" -2008 "$here\mem_backend_tb.vhd"
& "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null
& "$bin\xelab.bat" -L xpm -debug typical mem_backend_tb glbl -s mem_backend_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
& "$bin\xsim.bat" mem_backend_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'MBT|ERROR|Error|Failure|FATAL|Time resolution' | ForEach-Object { $_.Line }
