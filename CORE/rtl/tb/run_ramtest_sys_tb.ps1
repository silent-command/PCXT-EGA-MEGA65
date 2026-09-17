# xsim run of ramtest_sys_tb: the REAL MCL86 8088 running the REAL 8088 BIOS
# (bios-xt.bin = sdcard/bios/pcxt-xt.rom) POST RAM test on the MEGA65 memory
# path: RAM.sv overlay -> KFSDRAM overlay -> mem_backend.vhd -> the framework's
# real HyperRAM path (arbiter with scaler/QNICE traffic, hyperram_ctrl, HyperBus
# device model) or, with -Model, mem_backend_tb.vhd's compact hr_model; with the
# real bus arbiter / KF8237 overlay (DRAM refresh DMA) / READY / PIC / PIT / PPI.
#
# Reproduction of the Max-only "Faulty memory at 32 KiB": -Model -Speed 3 -Repro
# (pre-fix RAM.sv from rtl/tb/repro) drops writes and ends in low_ram_fail;
# without -Repro (the fixed overlay) every speed passes.
#
#   powershell -File run_ramtest_sys_tb.ps1 -Speed 0|1|2|3   # 4.77 / 7.16 / 9.54 / Max (default 3)
#   powershell -File run_ramtest_sys_tb.ps1 -Speed 3 -RamKB 64
#   powershell -File run_ramtest_sys_tb.ps1 -Speed 3 -Repro  # pre-fix RTL from rtl/tb/repro/ (by basename) instead of the overlays
#   powershell -File run_ramtest_sys_tb.ps1 -NoPatch         # keep the beep/keyboard delays (slow)
#   -Ring n      ring log depth (default 512)
#   -NoCompile   reuse the last elaboration (only the plusargs change)
#   -Model       compact hr_model behind mem_backend instead of the framework HyperRAM path (faster, pessimistic)
#   -CycFrom/-CycTo <ns>   cycle-by-cycle dump of the READY path in that window
#   -Work <dir>  work directory under CORE/ooc (default ramtest_sys_tb); use another for a parallel run
#   -Trace       write every bus event from the start of ram_test_block(32 KB) to ooc/ramtest_sys_tb/trace.txt (-testplusarg TRACELOW: from POST 04)
#
# Full log: CORE/ooc/ramtest_sys_tb/run_<speed>[_repro].log
param([string]$Bios = "", [int]$Speed = 3, [int]$RamKB = 64, [switch]$Repro, [switch]$NoPatch, [switch]$NoCompile, [int]$Ring = 512, [switch]$FullLowTest, [switch]$Trace, [switch]$Model, [int]$CycFrom = 0, [int]$CycTo = 0, [string]$Work = 'ramtest_sys_tb')
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$sub    = Join-Path $core 'PCXT-EGA_MiSTer'
$hdl     = Join-Path $sub 'rtl\KFPC-XT\HDL'
$cpu     = Join-Path $sub 'rtl\8088'
$overlay = Join-Path $core 'rtl\overlay'
$reproDir = Join-Path $here 'repro'
$vhdl    = Join-Path $core 'vhdl'
$m2m     = Resolve-Path (Join-Path $core '..\M2M\vhdl\memory')
$hr      = Resolve-Path (Join-Path $core '..\M2M\vhdl\controllers\hyperram')
$bios    = Join-Path $sub 'SW\8088_bios\binaries\bios-xt.bin'
if ($Bios -ne "") { $bios = (Resolve-Path $Bios).Path }   # -Bios: run another XT BIOS image

# the overlay as shipped, or the pre-fix copy kept in rtl/tb/repro for the reproduction run
function Ov($name) {
    if ($Repro -and (Test-Path (Join-Path $reproDir $name))) { return (Join-Path $reproDir $name) }
    return (Join-Path $overlay $name)
}

$sv = @(
    (Join-Path $here 'ramtest_sys_tb.sv'),
    (Join-Path $cpu  'wrappers\i8088.sv'),
    (Join-Path $cpu  'mcl86_biu_max.sv'),
    (Join-Path $cpu  'mcl86_eu_core.sv'),
    (Join-Path $cpu  'mcl86_ucode.sv'),
    (Join-Path $cpu  'mcl86_adder.sv'),
    (Join-Path $hdl  'XT_CE_Generator.sv'),
    (Join-Path $hdl  'Bus_Arbiter.sv'),
    (Join-Path $hdl  'Ready.sv'),
    (Join-Path $hdl  'KF8288\HDL\KF8288.sv'),
    (Ov 'KF8237.sv'),
    (Ov 'KF8237_Address_And_Count_Registers.sv'),
    (Join-Path $hdl  'KF8237\HDL\KF8237_Bus_Control_Logic.sv'),
    (Join-Path $hdl  'KF8237\HDL\KF8237_Priority_Encoder.sv'),
    (Join-Path $hdl  'KF8237\HDL\KF8237_Timing_And_Control.sv'),
    (Ov 'RAM.sv'),
    (Ov 'KFSDRAM.sv'),
    (Join-Path $hdl 'KFPS2KB\HDL\KFPS2KB.sv'),
    (Join-Path $hdl 'KFPS2KB\HDL\KFPS2KB_Shift_Register.sv'),
    (Join-Path $hdl 'KFPS2KB\HDL\KFPS2KB_Send_Data.sv'),
    (Join-Path $hdl 'KF8255\HDL\KF8255.sv'),
    (Join-Path $hdl 'KF8255\HDL\KF8255_Control_Logic.sv'),
    (Join-Path $hdl 'KF8255\HDL\KF8255_Group.sv'),
    (Join-Path $hdl 'KF8255\HDL\KF8255_Port.sv'),
    (Join-Path $hdl 'KF8255\HDL\KF8255_Port_C.sv'),
    (Join-Path $hdl 'KF8259\HDL\KF8259.sv'),
    (Join-Path $hdl 'KF8259\HDL\KF8259_Bus_Control_Logic.sv'),
    (Join-Path $overlay 'KF8259_Control_Logic.sv'),
    (Join-Path $hdl 'KF8259\HDL\KF8259_Interrupt_Request.sv'),
    (Join-Path $hdl 'KF8259\HDL\KF8259_Priority_Resolver.sv'),
    (Join-Path $hdl 'KF8259\HDL\KF8259_In_Service.sv'),
    (Join-Path $hdl 'KF8253\HDL\KF8253.sv'),
    (Join-Path $hdl 'KF8253\HDL\KF8253_Control_Logic.sv'),
    (Join-Path $hdl 'KF8253\HDL\KF8253_Counter.sv'),
    (Join-Path $hdl 'keyboard_warm_reset.sv')
)
$inc = @('-i', (Join-Path $hdl 'KF8255\HDL'), '-i', (Join-Path $hdl 'KF8259\HDL'), '-i', (Join-Path $hdl 'KF8253\HDL'), '-i', (Join-Path $hdl 'KF8237\HDL'))

$tag = if ($Repro) { 'REPRO (rtl/tb/repro RTL)' } else { 'overlay RTL as shipped' }
$tag += if ($Model) { ', hr_model' } else { ', real HyperRAM path' }
Write-Output "=== ramtest_sys_tb : speed $Speed, $RamKB KB, $tag ==="

$work = Join-Path $core ('ooc\' + $Work)
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
Copy-Item -Force (Join-Path $cpu 'mcl86_ucode.mem') $work
Copy-Item -Force $bios (Join-Path $work 'bios-xt.bin')

if (-not $NoCompile) {
    & "$bin\xvhdl.bat" --work xpm "$vivado\data\ip\xpm\xpm_VCOMP.vhd" | Out-Null
    & "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv" | Out-Null
    & "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_memory\hdl\xpm_memory.sv" | Out-Null
    & "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_fifo\hdl\xpm_fifo.sv" | Out-Null
    & "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null
    & "$bin\xvhdl.bat" -2008 "$m2m\axi_fifo.vhd" "$m2m\avm_fifo.vhd" "$m2m\avm_cache.vhd" "$m2m\avm_arbit.vhd" "$m2m\avm_arbit_general.vhd" "$hr\hyperram_errata.vhd" "$hr\hyperram_config.vhd" "$hr\hyperram_ctrl.vhd" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    & "$bin\xvhdl.bat" -2008 "$vhdl\mem_backend.vhd" "$here\mem_backend_tb.vhd" "$here\ramtest_mem_model.vhd" "$vhdl\ps2_tx.vhd" "$vhdl\keyboard.vhd" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (VHDL does not compile)"; exit 1 }

    $def = @(); if ($Model) { $def = @('-d', 'USE_HR_MODEL') }
    & "$bin\xvlog.bat" -sv @def @inc @sv 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }

    & "$bin\xelab.bat" -L xpm -debug typical work.ramtest_sys_tb glbl -s ramtest_sys_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }
}

# embedded quotes: xsim.bat goes through cmd.exe, which would otherwise split the argument at the '='
$plus = @('-testplusarg', "`"SPEED=$Speed`"", '-testplusarg', "`"RAMKB=$RamKB`"", '-testplusarg', "`"RING=$Ring`"")
if ($NoPatch)     { $plus += @('-testplusarg', 'NOPATCH') }
if ($FullLowTest) { $plus += @('-testplusarg', 'FULLLOWTEST') }
if ($Trace)       { $plus += @('-testplusarg', 'TRACE') }
if ($CycTo -gt 0) { $plus += @('-testplusarg', "`"CYCFROM=$CycFrom`"", '-testplusarg', "`"CYCTO=$CycTo`"") }
$log = "run_$Speed" + $(if ($Repro) { '_repro' } else { '' }) + '.log'
& "$bin\xsim.bat" ramtest_sys_sim -R @plus 2>&1 | Tee-Object -FilePath $log |
    Select-String -Pattern 'RESULT|---|CYC |\*\*\*|CHECK FAILED|observations|running|patch|loaded|reset|OUT 80h|memory_size|started|VERDICT|MISMATCH|^\s+\d+:' | ForEach-Object { $_.Line }
