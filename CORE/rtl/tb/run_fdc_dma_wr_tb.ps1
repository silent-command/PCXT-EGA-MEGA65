# xsim run of fdc_dma_wr_tb: the REAL KF8237 + REAL XT_CE_Generator + REAL READY
# + REAL RAM.sv + REAL KFSDRAM (overlays) + a variable-latency Avalon backend
# (HyperRAM model) + the Bus_Arbiter hold FSM / Peripherals fdd_dma glue,
# driving a synthetic channel-2 RECEIVER that matches floppy.v's write-path
# contract. Tests the MEMORY->DEVICE DMA direction a floppy WRITE uses.
#
#   powershell -File run_fdc_dma_wr_tb.ps1
#
# Vivado xsim only. Full log: CORE/ooc/fdc_dma_wr_tb/run.log
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
$hdl     = Join-Path $sub 'rtl\KFPC-XT\HDL'
$dma     = Join-Path $hdl 'KF8237\HDL'
$overlay = Join-Path $core 'rtl\overlay'

$work = Join-Path $core 'ooc\fdc_dma_wr_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

# Same rule as the build: a file in CORE/rtl/overlay replaces the upstream
# file with the same basename.
function Src([string]$dir, [string]$name) {
    $o = Join-Path $overlay $name
    if (Test-Path $o) { $o } else { Join-Path $dir $name }
}

& "$bin\xvlog.bat" -sv -i $dma `
    "$here\fdc_dma_wr_tb.sv" `
    (Src $hdl 'XT_CE_Generator.sv') `
    (Src $hdl 'Ready.sv') `
    "$overlay\RAM.sv" `
    "$overlay\KFSDRAM.sv" `
    (Src $dma 'KF8237.sv') `
    (Src $dma 'KF8237_Bus_Control_Logic.sv') `
    (Src $dma 'KF8237_Priority_Encoder.sv') `
    (Src $dma 'KF8237_Address_And_Count_Registers.sv') `
    (Src $dma 'KF8237_Timing_And_Control.sv') 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }

& "$bin\xelab.bat" -debug off work.fdc_dma_wr_tb -s fdc_dma_wr_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }

& "$bin\xsim.bat" fdc_dma_wr_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'RESULT|HRQ|CHECK|TIMEOUT|Programming|Starting|byte\[' | ForEach-Object { $_.Line }
