# xsim run of fdc_bios_tb: the REAL floppy.v + REAL KF8259 + a verbatim copy of
# the Peripherals.sv fdd I/O-edge-latch glue and IR6 wiring, driven by a
# behavioural CPU that runs the Super PC/Turbo XT BIOS v3.1 NEC 765 port
# sequence with the real MSR handshake and services IRQ6 through the 8259.
#
#   powershell -File run_fdc_bios_tb.ps1          # upstream floppy.v (reproduce)
#   powershell -File run_fdc_bios_tb.ps1 -Fix     # overlay floppy.v  (verify fix)
#
# NOTE: xsim only (KF8259 uses SystemVerilog Icarus 12 rejects).
# Full log: CORE/ooc/fdc_bios_tb/run.log
param([switch]$Fix)
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')

# The submodule is empty inside a git worktree; walk up to the main checkout.
$sub = Join-Path $core 'PCXT-EGA_MiSTer'
if (-not (Test-Path (Join-Path $sub 'rtl\KFPC-XT\HDL\XT_CE_Generator.sv'))) {
    $d = [string]$core
    while ($d -and -not (Test-Path (Join-Path $d 'CORE\PCXT-EGA_MiSTer\rtl\KFPC-XT\HDL\XT_CE_Generator.sv'))) {
        $d = Split-Path -Parent $d
    }
    $sub = Join-Path $d 'CORE\PCXT-EGA_MiSTer'
}
$hdl    = Join-Path $sub 'rtl\KFPC-XT\HDL'
$common = Join-Path $sub 'rtl\common'
$pic    = Join-Path $hdl 'KF8259\HDL'

# Both runs use the overlay floppy.v (CORE/rtl/overlay/floppy.v). It is upstream
# floppy.v with two behaviour-neutral syntax changes so xsim's xvlog accepts it
# in Verilog-2005 mode (unpacked "[2]" -> "[0:1]", one named block) plus the
# irq fix guarded by `ifndef FDC_NO_IRQ_FIX`. Compiling with FDC_NO_IRQ_FIX
# defined reproduces the exact upstream logic (fix removed); without it exercises
# the fix. floppy.v is compiled in DEFAULT (Verilog) mode, NOT -sv, because -sv
# forbids the file's forward localparam references (Vivado's synthesis
# front-end, which the real build uses, accepts them).
$floppy = Join-Path $core 'rtl\overlay\floppy.v'
if ($Fix) { $tag = 'FIX (overlay floppy.v, irq fix ON)';  $fdef = @() }
else       { $tag = 'REPRO (upstream logic, irq fix OFF)'; $fdef = @('-d','FDC_NO_IRQ_FIX') }
Write-Output "=== fdc_bios_tb : $tag ==="

$work = Join-Path $core 'ooc\fdc_bios_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvlog.bat" @fdef "$floppy" "$common\simple_fifo.v" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (floppy.v does not compile)"; exit 1 }

& "$bin\xvlog.bat" -sv `
    "$here\fdc_bios_tb.sv" `
    "$pic\KF8259.sv" `
    "$pic\KF8259_Bus_Control_Logic.sv" `
    "$pic\KF8259_Control_Logic.sv" `
    "$pic\KF8259_Interrupt_Request.sv" `
    "$pic\KF8259_Priority_Resolver.sv" `
    "$pic\KF8259_In_Service.sv" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }

& "$bin\xelab.bat" -debug typical work.fdc_bios_tb -s fdc_bios_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }

& "$bin\xsim.bat" fdc_bios_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'RESULT|phase|observations|IRQ6|cmd_read_write|DACK|DMA bytes|mgmt read|interrupt_to_cpu|DIVERGENCE|CHECK FAILED' | ForEach-Object { $_.Line }
