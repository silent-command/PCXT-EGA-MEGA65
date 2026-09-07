# Load a bitstream into the MEGA65's FPGA over JTAG (volatile: lost at power-off).
# Usage (PowerShell):  tools\jtag-load.ps1 [path\to\file.bit]
# Defaults to the R6 implementation output of this repo.
#
# Uses m65.exe from mega65-tools. The JTAG adapter's channel A must be bound
# to the WinUSB driver (done once with Zadig); channel B stays on the FTDI
# driver and is the serial console (COM port).
param(
    [string]$Bit = (Join-Path $PSScriptRoot '..\CORE\CORE-R6.runs\impl_1\mega65_r6.bit'),
    [string]$M65Tools = $env:M65TOOLS
)
if (-not $M65Tools) {
    $M65Tools = Get-ChildItem (Join-Path $PSScriptRoot '..\..') -Directory -Filter 'm65tools-*' |
        Select-Object -First 1 -ExpandProperty FullName
}
$m65 = Join-Path $M65Tools 'm65.exe'
if (-not (Test-Path $m65)) { throw "m65.exe not found (M65TOOLS='$M65Tools'). Get mega65-tools from https://github.com/MEGA65/mega65-tools" }
$Bit = (Resolve-Path $Bit).Path
& $m65 -q $Bit
exit $LASTEXITCODE
