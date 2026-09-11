# xsim run of analog_pipeline_tb: the REAL framework analog (VGA) path of this port -
# CORE/vhdl/analog_video_ctl.vhd + xpm_cdc_array_single + M2M analog_pipeline.vhd with its
# MiSTer Verilog (video_mixer / scandoubler / hq2x / video_freezer / csync) and the VHDL overlay
# (video_overlay / vga_recover_counters / vga_osm / ram_init) - driven with the 200-line raster
# and measured at the VGA pins. See the header of analog_pipeline_tb.sv and docs/analog-video.md.
#   powershell -File run_analog_pipeline_tb.ps1
# Full log: CORE/ooc/analog_pipeline_tb/run.log
$ErrorActionPreference = 'Continue'
$vivado = 'C:\AMDDesignTools\2026.1\Vivado'
$bin    = "$vivado\bin"
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$core   = Resolve-Path (Join-Path $here '..\..')
$root   = Resolve-Path (Join-Path $core '..')
$m2m    = Join-Path $root 'M2M\vhdl'
$av     = Join-Path $m2m 'av_pipeline'
$mister = Join-Path $m2m 'controllers\MiSTer'
$work   = Join-Path $core 'ooc\analog_pipeline_tb'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

# XPM (the framework's CDC primitive)
& "$bin\xvhdl.bat" --work xpm "$vivado\data\ip\xpm\xpm_VCOMP.vhd" | Out-Null
& "$bin\xvlog.bat" -sv --work xpm "$vivado\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv" | Out-Null

# MiSTer Verilog inside the framework (unchanged)
& "$bin\xvlog.bat" -sv "$mister\video_freezer.sv" "$mister\hq2x.sv" "$mister\scandoubler.v" "$mister\video_mixer.sv" "$mister\csync.sv" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "APT RESULT: FAIL (MiSTer Verilog does not compile)"; exit 1 }

# xsim quirk (mixed language): analog_pipeline.vhd:141-143 pass "R => unsigned(video_red_i)" - a type
# conversion inside the port map - to the Verilog module video_mixer. xelab accepts it, but at time 0
# xsim aborts with "Array sizes do not match, left array has 0 elements, right array has 8 elements"
# (reproduced with a 60-line probe; an unsigned signal or an slv component port both work). Vivado
# synthesis binds the same code correctly (build-r6.log: Synth 8-3491, no width warnings). The bench
# therefore compiles a copy of analog_pipeline.vhd in which the three conversions are moved into
# signal assignments (video_red_u <= unsigned(video_red_i); R => video_red_u; ...). That is the only
# change, verified below; the M2M source is not touched.
$apSrc = Get-Content (Join-Path $av 'analog_pipeline.vhd') -Raw
$apSim = $apSrc
$apSim = $apSim -replace '(?m)^   component video_mixer is', "   -- xsim: port-map conversions of analog_pipeline.vhd:141-143 moved here (see run_analog_pipeline_tb.ps1)`n   signal video_red_u        : unsigned(7 downto 0);`n   signal video_green_u      : unsigned(7 downto 0);`n   signal video_blue_u       : unsigned(7 downto 0);`n`n   component video_mixer is"
$apSim = $apSim -replace '(?m)^   i_video_mixer : video_mixer', "   video_red_u   <= unsigned(video_red_i);`n   video_green_u <= unsigned(video_green_i);`n   video_blue_u  <= unsigned(video_blue_i);`n`n   i_video_mixer : video_mixer"
$apSim = $apSim -replace 'R           => unsigned\(video_red_i\),',   'R           => video_red_u,'
$apSim = $apSim -replace 'G           => unsigned\(video_green_i\),', 'G           => video_green_u,'
$apSim = $apSim -replace 'B           => unsigned\(video_blue_i\),',  'B           => video_blue_u,'
$n1 = ([regex]::Matches($apSrc, 'unsigned\(video_(red|green|blue)_i\)')).Count
$n2 = ([regex]::Matches($apSim, 'unsigned\(video_(red|green|blue)_i\)')).Count
$n3 = ([regex]::Matches($apSim, '=> video_(red|green|blue)_u,')).Count
if ($n1 -ne 3 -or $n2 -ne 3 -or $n3 -ne 3 -or $apSim -notmatch 'signal video_red_u') {
    Write-Output "APT RESULT: FAIL (analog_pipeline.vhd transform for xsim did not apply as expected: $n1/$n2/$n3)"; exit 1
}
Set-Content -Path (Join-Path $work 'analog_pipeline_sim.vhd') -Value $apSim -Encoding ascii

# framework VHDL + the port's control block
& "$bin\xvhdl.bat" -2008 "$m2m\ram_init.vhd" "$av\vga_osm.vhd" "$av\vga_recover_counters.vhd" "$av\video_overlay.vhd" "$work\analog_pipeline_sim.vhd" "$core\vhdl\analog_video_ctl.vhd" "$here\analog_pipeline_wrap.vhd" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "APT RESULT: FAIL (framework VHDL does not compile)"; exit 1 }

# bench
& "$bin\xvlog.bat" -sv "$here\analog_pipeline_tb.sv" 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "APT RESULT: FAIL (bench does not compile)"; exit 1 }
& "$bin\xvlog.bat" "$vivado\data\verilog\src\glbl.v" | Out-Null

$font = (Join-Path $root 'M2M\font\Anikki-16x16-m2m.rom') -replace '\\', '/'
& "$bin\xelab.bat" -L xpm -debug off -generic_top "`"FONT_FILE=$font`"" analog_pipeline_tb glbl -s analog_pipeline_sim 2>&1 | Select-String -Pattern 'ERROR' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { Write-Output "APT RESULT: FAIL (elaboration failed)"; exit 1 }

& "$bin\xsim.bat" analog_pipeline_sim -R 2>&1 | Tee-Object -FilePath run.log | Select-String -Pattern 'APT|RESULT|CSYNC|ERR|Error|Failure|FATAL' | ForEach-Object { $_.Line }
