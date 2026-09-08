# Capture the M2M firmware's serial debug log from the JTAG adapter's second
# channel (FTDI channel B, COM8 on this PC), optionally reloading the core over
# JTAG first so the boot messages are captured from the start.
#   tools\serial-log.ps1 [-Seconds 60] [-Port COM8] [-Reload] [-Bit path\to.bit]
param(
    [int]$Seconds = 60,
    [string]$Port = 'COM8',
    [switch]$Reload,
    [string]$Bit = ''
)
$job = Start-Job -ArgumentList $Port, $Seconds -ScriptBlock {
    param($port, $seconds)
    $p = New-Object System.IO.Ports.SerialPort $port, 115200, 'None', 8, 'One'
    $p.ReadTimeout = 500
    $p.Open()
    $sb = New-Object System.Text.StringBuilder
    $t0 = Get-Date
    $end = $t0.AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        try {
            $s = $p.ReadExisting()
            if ($s) { [void]$sb.Append(('[{0,6:0.0}s] ' -f ((Get-Date) - $t0).TotalSeconds) + $s) }
        } catch {}
        Start-Sleep -Milliseconds 100
    }
    $p.Close()
    $sb.ToString()
}
Start-Sleep -Seconds 1
if ($Reload) {
    $loader = Join-Path $PSScriptRoot 'jtag-load.ps1'
    if ($Bit) { & $loader -Bit $Bit | Select-Object -Last 1 } else { & $loader | Select-Object -Last 1 }
}
Wait-Job $job | Out-Null
$out = Receive-Job $job
Remove-Job $job
"--- $Port capture, $Seconds s, $($out.Length) chars ---"
$out
