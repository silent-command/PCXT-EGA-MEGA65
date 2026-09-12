# xsim run of kbd_bios_sys_tb: the REAL MCL86 8088 running the REAL 8088 BIOS
# (bios-xt.bin) on the real bus arbiter / ready / PIC / PIT / PPI / KFPS2KB and
# the real MEGA65 PS/2 keyboard device.
#
#   powershell -File run_kbd_bios_sys_tb.ps1              # 4.77 MHz
#   powershell -File run_kbd_bios_sys_tb.ps1 -Max         # "Max" CPU speed setting
#   powershell -File run_kbd_bios_sys_tb.ps1 -Fix         # with the CORE/rtl/overlay fix
#   powershell -File run_kbd_bios_sys_tb.ps1 -NoPatch     # keep the beepinit delay
#
# Full log: CORE/ooc/kbd_bios_sys_tb/run.log
param([switch]$Max, [switch]$Fix, [switch]$NoPatch)
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
$cpu     = Join-Path $sub 'rtl\8088'
$overlay = Join-Path $core 'rtl\overlay'
$vhdl    = Join-Path $core 'vhdl'
$bios    = Join-Path $sub 'SW\8088_bios\binaries\bios-xt.bin'

function Pick($name, $dir) {
    $o = Join-Path $overlay $name
    if ($Fix -and (Test-Path $o)) { return $o }
    return (Join-Path $dir $name)
}

# The KF8237 overlay (timing-only rewrite of the register read path) is what the
# real build uses; it is also the version whose Address_And_Count_Registers has
# the extra address_in port, so the pair must be taken together.
$sv = @(
    (Join-Path $here 'kbd_bios_sys_tb.sv'),
    (Join-Path $cpu  'wrappers\i8088.sv'),
    (Join-Path $cpu  'mcl86_biu_max.sv'),
    (Join-Path $cpu  'mcl86_eu_core.sv'),
    (Join-Path $cpu  'mcl86_ucode.sv'),
    (Join-Path $cpu  'mcl86_adder.sv'),
    (Join-Path $hdl  'XT_CE_Generator.sv'),
    (Join-Path $hdl  'Bus_Arbiter.sv'),
    (Join-Path $hdl  'Ready.sv'),
    (Join-Path $hdl  'KF8288\HDL\KF8288.sv'),
    (Join-Path $overlay 'KF8237.sv'),
    (Join-Path $overlay 'KF8237_Address_And_Count_Registers.sv'),
    (Join-Path $hdl  'KF8237\HDL\KF8237_Bus_Control_Logic.sv'),
    (Join-Path $hdl  'KF8237\HDL\KF8237_Priority_Encoder.sv'),
    (Join-Path $hdl  'KF8237\HDL\KF8237_Timing_And_Control.sv'),
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
$inc = @('-i', (Join-Path $hdl 'KF8255\HDL'), '-i', (Join-Path $hdl 'KF8259\HDL'), '-i', (Join-Path $hdl 'KF8253\HDL'), '-i', (Join-Path $hdl 'KF8237\HDL'))

$tag = if ($Fix) { 'FIX (overlay RTL)' } else { 'REPRO (upstream RTL)' }
Write-Output "=== kbd_bios_sys_tb : $tag ==="

$work = Join-Path $core 'ooc\kbd_bios_sys_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
Copy-Item -Force (Join-Path $cpu 'mcl86_ucode.mem') $work
Copy-Item -Force $bios (Join-Path $work 'bios-xt.bin')

& "$bin\xvhdl.bat" --2008 (Join-Path $vhdl 'ps2_tx.vhd') (Join-Path $vhdl 'keyboard.vhd') 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (VHDL does not compile)"; exit 1 }

& "$bin\xvlog.bat" -sv @inc @sv 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (bench does not compile)"; exit 1 }

& "$bin\xelab.bat" -debug typical work.kbd_bios_sys_tb -s kbd_bios_sys_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT: FAIL (elaboration failed)"; exit 1 }

$plus = @()
if ($Max)     { $plus += @('-testplusarg', 'MAXSPEED') }
if ($NoPatch) { $plus += @('-testplusarg', 'NOPATCH') }
& "$bin\xsim.bat" kbd_bios_sys_sim -R @plus 2>&1 | Tee-Object -FilePath run.log |
    Select-String -Pattern 'RESULT|---|IN 60h|IMR|\*\*\*|CHECK FAILED|observations|values:|final:|running|patch|loaded|reset|unmasked|HLT|BDA|RING|DELIVERED|program' | ForEach-Object { $_.Line }
