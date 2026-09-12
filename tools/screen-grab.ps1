# Grab one frame of the MEGA65's HDMI output from the USB capture stick.
# Usage:  tools\screen-grab.ps1 [-Out path.jpg] [-Device "USB Video"] [-Size 1920x1080]
# Needs ffmpeg (winget install Gyan.FFmpeg). The stick is a MacroSilicon-type
# device that shows up as the DirectShow camera "USB Video" (MJPEG).
param(
    [string]$Out = (Join-Path $PSScriptRoot '..\out\screen.jpg'),
    [string]$Device = 'USB Video',
    [string]$Size = '1920x1080',
    [int]$Skip = 5      # frames to discard while the stick settles
)
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ff) {
    $ff = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue |
          Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ff) { throw "ffmpeg not found; winget install Gyan.FFmpeg" }
$Out = [System.IO.Path]::GetFullPath($Out)
$dir = Split-Path $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
if (Test-Path $Out) { Remove-Item $Out -Force }
# -vcodec mjpeg selects the stick's native stream; skip a few frames, keep one, no re-encode loss beyond a JPEG.
& $ff -hide_banner -loglevel fatal -y -f dshow -vcodec mjpeg -video_size $Size -i "video=$Device" `
      -vf "select=gte(n\,$Skip)" -frames:v 1 -q:v 3 $Out
if ((Test-Path $Out) -and ((Get-Item $Out).Length -gt 0)) {
    "grab: $Out ($((Get-Item $Out).Length) bytes) $(Get-Date -Format HH:mm:ss)"
    exit 0
} else {
    Write-Error "grab failed (is the stick connected and the MEGA65 HDMI plugged into it?)"
    exit 1
}
