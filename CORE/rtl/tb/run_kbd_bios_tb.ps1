# xsim run of kbd_bios_tb: the REAL keyboard.vhd + ps2_tx.vhd (MEGA65 PS/2
# device), KFPS2KB, KF8255, KF8259, KF8253 and keyboard_warm_reset behind a
# verbatim copy of the Peripherals.sv / PCXT-EGA.sv keyboard glue, driven by a
# behavioural 8088 that runs either BIOS's POST / INT 9 port sequence.
#
#   powershell -File run_kbd_bios_tb.ps1                 # both BIOSes, upstream RTL
#   powershell -File run_kbd_bios_tb.ps1 -Bios 8088      # one BIOS
#   powershell -File run_kbd_bios_tb.ps1 -Fix            # with the CORE/rtl/overlay fix
#
# Full logs: CORE/ooc/kbd_bios_tb/run_<bios>.log
param([string]$Bios = 'both', [switch]$Fix)
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')

$sub = Join-Path $core 'PCXT-EGA_MiSTer'
if (-not (Test-Path (Join-Path $sub 'rtl\KFPC-XT\HDL\XT_CE_Generator.sv'))) {
    $d = [string]$core
    while ($d -and -not (Test-Path (Join-Path $d 'CORE\PCXT-EGA_MiSTer\rtl\KFPC-XT\HDL\XT_CE_Generator.sv'))) {
        $d = Split-Path -Parent $d
    }
    $sub = Join-Path $d 'CORE\PCXT-EGA_MiSTer'
}
$hdl     = Join-Path $sub 'rtl\KFPC-XT\HDL'
$overlay = Join-Path $core 'rtl\overlay'
$vhdl    = Join-Path $core 'vhdl'

# Overlay files replace upstream ones by basename (as the build does)
function Pick($name, $dir) {
    $o = Join-Path $overlay $name
    if ($Fix -and (Test-Path $o)) { return $o }
    return (Join-Path $dir $name)
}

$sv = @(
    (Join-Path $here 'kbd_bios_tb.sv'),
    (Pick 'KFPS2KB.sv'                (Join-Path $hdl 'KFPS2KB\HDL')),
    (Pick 'KFPS2KB_Shift_Register.sv' (Join-Path $hdl 'KFPS2KB\HDL')),
    (Pick 'KFPS2KB_Send_Data.sv'      (Join-Path $hdl 'KFPS2KB\HDL')),
    (Pick 'KF8255.sv'                 (Join-Path $hdl 'KF8255\HDL')),
    (Pick 'KF8255_Control_Logic.sv'   (Join-Path $hdl 'KF8255\HDL')),
    (Pick 'KF8255_Group.sv'           (Join-Path $hdl 'KF8255\HDL')),
    (Pick 'KF8255_Port.sv'            (Join-Path $hdl 'KF8255\HDL')),
    (Pick 'KF8255_Port_C.sv'          (Join-Path $hdl 'KF8255\HDL')),
    (Pick 'KF8259.sv'                 (Join-Path $hdl 'KF8259\HDL')),
    (Pick 'KF8259_Bus_Control_Logic.sv' (Join-Path $hdl 'KF8259\HDL')),
    (Pick 'KF8259_Control_Logic.sv'   (Join-Path $hdl 'KF8259\HDL')),
    (Pick 'KF8259_Interrupt_Request.sv' (Join-Path $hdl 'KF8259\HDL')),
    (Pick 'KF8259_Priority_Resolver.sv' (Join-Path $hdl 'KF8259\HDL')),
    (Pick 'KF8259_In_Service.sv'      (Join-Path $hdl 'KF8259\HDL')),
    (Pick 'KF8253.sv'                 (Join-Path $hdl 'KF8253\HDL')),
    (Pick 'KF8253_Control_Logic.sv'   (Join-Path $hdl 'KF8253\HDL')),
    (Pick 'KF8253_Counter.sv'         (Join-Path $hdl 'KF8253\HDL')),
    (Pick 'keyboard_warm_reset.sv'    $hdl)
)
$inc = @('-i', (Join-Path $hdl 'KF8255\HDL'), '-i', (Join-Path $hdl 'KF8259\HDL'), '-i', (Join-Path $hdl 'KF8253\HDL'))

$tag = if ($Fix) { 'FIX (overlay RTL)' } else { 'REPRO (upstream RTL)' }
Write-Output "=== kbd_bios_tb : $tag ==="

$work = Join-Path $core 'ooc\kbd_bios_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

& "$bin\xvhdl.bat" --2008 (Join-Path $vhdl 'ps2_tx.vhd') (Join-Path $vhdl 'keyboard.vhd') 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (VHDL does not compile)"; exit 1 }

& "$bin\xvlog.bat" -sv @inc @sv 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }

& "$bin\xelab.bat" -debug typical work.kbd_bios_tb -s kbd_bios_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }

$list = if ($Bios -eq 'both') { @('8088', 'TURBO') } else { @($Bios) }
foreach ($b in $list) {
    Write-Output "=== BIOS=$b ==="
    # xsim.bat (cmd.exe) splits arguments on '=', so the BIOS choice is a bare plusarg flag
    $plus = if ($b -eq 'TURBO') { @('-testplusarg', 'TURBO') } else { @() }
    & "$bin\xsim.bat" kbd_bios_sim -R @plus 2>&1 | Tee-Object -FilePath "run_$b.log" |
        Select-String -Pattern 'RESULT|---|INT 9:|IMR|\*\*\*|CHECK FAILED|observations|scancodes|final:' | ForEach-Object { $_.Line }
}
