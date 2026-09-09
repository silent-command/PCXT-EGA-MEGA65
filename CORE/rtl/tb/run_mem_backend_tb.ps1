# xsim run of mem_backend_tb: VHDL DUT (mem_backend.vhd) + M2M avm_fifo/avm_cache + XPM + the framework's
# HyperRAM path (avm_arbit_general, hyperram_errata/config/ctrl) with a HyperBus device model in the bench.
#   powershell -File run_mem_backend_tb.ps1 [-Seed n] [-Model]
#     -Seed n   picks another random sequence (default 1)
#     -Model    use the bench's compact hr_model instead of the framework RTL (faster)
# Full log: CORE/ooc/mem_backend_tb/run.log
param([int]$Seed = 1, [switch]$Model)
$real = if ($Model) { 'false' } else { 'true' }
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
$hr = Resolve-Path (Join-Path $core '..\M2M\vhdl\controllers\hyperram')
& "$bin\xvhdl.bat" -2008 "$m2m\axi_fifo.vhd" "$m2m\avm_fifo.vhd" "$m2m\avm_cache.vhd" "$m2m\avm_arbit.vhd" "$m2m\avm_arbit_general.vhd" "$hr\hyperram_errata.vhd" "$hr\hyperram_config.vhd" "$hr\hyperram_ctrl.vhd"
& "$bin\xvhdl.bat" -2008 "$core\vhdl\mem_backend.vhd"
& "$bin\xvhdl.bat" -2008 "$here\mem_backend_tb.vhd"
if ($LASTEXITCODE -ne 0) { Write-Output "MBT RESULT: FAIL (bench does not compile)"; exit 1 }
& "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null
& "$bin\xelab.bat" -L xpm -debug typical -generic_top "`"G_SEED=$Seed`"" -generic_top "`"G_REAL_PATH=$real`"" mem_backend_tb glbl -s mem_backend_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "MBT RESULT: FAIL (elaboration failed)"; exit 1 }
& "$bin\xsim.bat" mem_backend_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'MBT|ERROR|Error|Failure|FATAL|Time resolution' | ForEach-Object { $_.Line }
