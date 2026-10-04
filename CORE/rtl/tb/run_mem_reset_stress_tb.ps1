# xsim run of mem_reset_stress_tb: the reset button against the PC's memory path
# (mem_backend -> avm_fifo -> arbiter with scaler/QNICE traffic -> hyperram_errata /
# _config / _ctrl -> HyperBus device model), hundreds of presses at random moments,
# with a KFSDRAM-like master and a scoreboard. See the header of the bench.
#
#   powershell -File run_mem_reset_stress_tb.ps1 [-Resets 300] [-Seed 1] [-Bist] [-NoCompile] [-Work dir]
#   -Bist    mem_backend's self test after every reset, as on the core (slower: 1.3 ms + the test per reset)
#   -Mutate  negative control: mem_backend without the dummy beats that drain the reads a reset killed
#            (docs/reset-button.md). The bench must FAIL with hangs; if it passes it proves nothing.
#
# Full log: CORE/ooc/<Work>/run_<seed>.log
param([int]$Resets = 300, [int]$Seed = 1, [switch]$NoCompile, [switch]$Bist, [switch]$Mutate, [switch]$Debug, [string]$Work = 'mem_reset_stress_tb')
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$vhdl   = Join-Path $core 'vhdl'
$m2m    = Resolve-Path (Join-Path $core '..\M2M\vhdl\memory')
$hr     = Resolve-Path (Join-Path $core '..\M2M\vhdl\controllers\hyperram')

$work = Join-Path $core ('ooc\' + $Work)
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$backend = "$vhdl\mem_backend.vhd"
if ($Mutate) {
    $backend = Join-Path $work 'mem_backend_mutant.vhd'
    $src = Get-Content "$vhdl\mem_backend.vhd" -Raw
    $mut = $src.Replace("v_flush := rst_all = '1' and out_count /= 0 and not v_real;", "v_flush := false;")
    if ($mut -eq $src) { Write-Output "RESULT: FAIL (mutation did not apply)"; exit 1 }
    Set-Content -Path $backend -Value $mut -NoNewline
    Write-Output "=== NEGATIVE CONTROL: mem_backend without the drain ==="
}

if (-not $NoCompile) {
    & "$bin\xvhdl.bat" --work xpm "$vivado\data\ip\xpm\xpm_VCOMP.vhd" | Out-Null
    & "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv" | Out-Null
    & "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_memory\hdl\xpm_memory.sv" | Out-Null
    & "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_fifo\hdl\xpm_fifo.sv" | Out-Null
    & "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null
    & "$bin\xvhdl.bat" -2008 "$m2m\axi_fifo.vhd" "$m2m\avm_fifo.vhd" "$m2m\avm_cache.vhd" "$m2m\avm_arbit.vhd" "$m2m\avm_arbit_general.vhd" "$hr\hyperram_errata.vhd" "$hr\hyperram_config.vhd" "$hr\hyperram_ctrl.vhd" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    & "$bin\xvhdl.bat" -2008 "$backend" "$here\mem_backend_tb.vhd" "$here\ramtest_mem_model.vhd" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (VHDL does not compile)"; exit 1 }
    & "$bin\xvlog.bat" -sv (Join-Path $here 'mem_reset_stress_tb.sv') 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }
    # embedded quotes: xelab.bat goes through cmd.exe, which would otherwise split the argument at the '='
    $gen = @(); if ($Bist) { $gen = @('-generic_top', "`"BIST=1`"") }
    & "$bin\xelab.bat" -L xpm -debug typical @gen work.mem_reset_stress_tb glbl -s mem_reset_stress_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }
}
$plus = @('-testplusarg', "`"RESETS=$Resets`"", '-testplusarg', "`"SEED=$Seed`"")
if ($Debug) { $plus += @('-testplusarg', 'DEBUG') }
& "$bin\xsim.bat" mem_reset_stress_sim -R @plus 2>&1 | Tee-Object -FilePath "run_$Seed.log" |
    Select-String -Pattern 'RESULT|---|===|\*\*\*|resets:|press #|release #|backend:|debug:' | ForEach-Object { $_.Line }
