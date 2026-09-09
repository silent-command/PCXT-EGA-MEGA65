# xsim run of fdc_dma_8237_tb: the REAL KF8237 + REAL XT_CE_Generator + the real
# Bus_Arbiter hold FSM / Peripherals fdd_dma glue equations, driving a synthetic
# channel-2 peripheral that matches floppy.v's DMA contract. Validates the DMA
# channel-2 path that the chipset test suite skips.
#
#   powershell -File run_fdc_dma_8237_tb.ps1
#
# NOTE: this bench must run under Vivado xsim, NOT Icarus. The KF8237 RTL uses
# SystemVerilog that Icarus 12 rejects (array-slice assignment, enum casts,
# constant part-selects in always_* blocks) -- which is itself why the KF8237
# benches are absent from the Icarus chipset suite and its DMA path is untested.
#
# Full log: CORE/ooc/fdc_dma_8237_tb/run.log
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
$hdl = Join-Path $sub 'rtl\KFPC-XT\HDL'
$dma = Join-Path $hdl 'KF8237\HDL'

$work = Join-Path $core 'ooc\fdc_dma_8237_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvlog.bat" -sv -i $dma `
    "$here\fdc_dma_8237_tb.sv" `
    "$hdl\XT_CE_Generator.sv" `
    "$dma\KF8237.sv" `
    "$dma\KF8237_Bus_Control_Logic.sv" `
    "$dma\KF8237_Priority_Encoder.sv" `
    "$dma\KF8237_Address_And_Count_Registers.sv" `
    "$dma\KF8237_Timing_And_Control.sv" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }

& "$bin\xelab.bat" -debug off work.fdc_dma_8237_tb -s fdc_dma_8237_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }

& "$bin\xsim.bat" fdc_dma_8237_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'RESULT|HRQ|CHECK|TIMEOUT|Programming|Starting' | ForEach-Object { $_.Line }
