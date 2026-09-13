# Remove the diagnostic probes from the working tree.
#
# They are a DIAGNOSTIC-ONLY change and must not ship. Two investigations share one bitstream:
#
#   register 6 " vga=" : HSYNC / VSYNC rising edges counted AT THE FPGA PINS ("no signal on the VGA
#                        connector in every mode", docs/analog-video.md section 8)
#   register 7 " ctl=" : qnice_scandoubler / csync / retro15kHz, the live HSYNC, VSYNC and
#                        video_ce_ovl levels, and a counter that advances while video_ce_ovl runs
#   register 8 " hdd=" : rising edges of blk_ack(2) - hard-disk (vdrive 2) sectors served - as a
#                        16-bit count, instead of the shipping "{acks, writes} for floppy A"
#
# Every line they add or change is tagged "DIAG-PROBE". This script removes them all.
#
#   powershell -File tools/revert-diag-probe.ps1
#   powershell -File tools/revert-diag-probe.ps1 -WhatIf      (report only, change nothing)
#
# Touches: M2M/vhdl/top_mega65-r6.vhd, CORE/vhdl/mega65.vhd, CORE/vhdl/main.vhd,
#          CORE/m2m-rom/m2m-rom.asm.
# Afterwards rebuild the QNICE ROM so the shipping labels come back on the status line - the
# synthesis pre-hook (CORE/m2m-rom/synth_pre.tcl) does it automatically, or run
# CORE/m2m-rom/make_rom.sh under WSL by hand.
#
# It does NOT touch G_ANALOG_LINE_DOUBLER in top_mega65-r6.vhd: the 350-line analog line doubler is
# a real feature, not part of the probe.
param([switch]$WhatIf)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')
$changed = 0
$nl = "`n"

# ---------------------------------------------------------------------------------------------
# Blocks that are purely additive: drop every line from "DIAG-PROBE begin" to "DIAG-PROBE end"
# inclusive, plus a dashed banner immediately above and a single blank line immediately below.
# ---------------------------------------------------------------------------------------------
function Strip-Blocks([string]$text) {
    $lines = $text -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -match 'DIAG-PROBE begin') {
            while ($out.Count -gt 0 -and $out[$out.Count-1] -match '^\s*-{6,}\s*\r?$') { $out.RemoveAt($out.Count-1) }
            while ($i -lt $lines.Count -and $lines[$i] -notmatch 'DIAG-PROBE end') { $i++ }
            $i++
            if ($i -lt $lines.Count -and $lines[$i] -match '^\s*\r?$') { $i++ }
            continue
        }
        $out.Add($lines[$i])
        $i++
    }
    return ($out -join "`n")
}

function Edit-File([string]$rel, [scriptblock]$transform) {
    $path = Join-Path $root $rel
    $before = [IO.File]::ReadAllText($path)
    $after = & $transform $before
    if ($after -eq $before) { Write-Output "unchanged: $rel (probe already removed?)"; return }
    if ($WhatIf) { Write-Output "would change: $rel" }
    else { [IO.File]::WriteAllText($path, $after); Write-Output "reverted: $rel" }
    $script:changed++
}

# ---------------------------------------------------------------------------------------------
Edit-File 'M2M/vhdl/top_mega65-r6.vhd' {
    param($t)
    $t = Strip-Blocks $t
    $t = $t.Replace('      vga_hs_o                => vga_hs_probe,   -- DIAG-PROBE (was: vga_hs_o)',
                    '      vga_hs_o                => vga_hs_o,')
    $t = $t.Replace('      vga_vs_o                => vga_vs_probe,   -- DIAG-PROBE (was: vga_vs_o)',
                    '      vga_vs_o                => vga_vs_o,')
    return $t
}

Edit-File 'CORE/vhdl/mega65.vhd' {
    param($t)
    $t = Strip-Blocks $t
    $t = $t.Replace('         dbg_a_i           => dbg_vga_i,            -- DIAG-PROBE (was: main_dbg_bus_reads)',
                    '         dbg_a_i           => main_dbg_bus_reads,')
    $t = $t.Replace('         dbg_b_i           => dbg_ctl_i,            -- DIAG-PROBE (was: main_dbg_vsync)',
                    '         dbg_b_i           => main_dbg_vsync,')
    return $t
}

# main.vhd's blocks wrap MODIFIED lines, not added ones, so they are put back explicitly rather
# than stripped.
Edit-File 'CORE/vhdl/main.vhd' {
    param($t)

    $decl_new = @(
      "   -- DIAG-PROBE begin (DIAGNOSTIC BUILD ONLY, see docs/analog-video.md; original line:",
      "   --    signal wr_req_cnt, rd_req_cnt, blk_wr_cnt, blk_ack_cnt : unsigned(7 downto 0) := (others => '0');",
      "   -- blk_ack_cnt widened to 16 bits so a whole FreeDOS boot's worth of hard-disk sectors fits without",
      "   -- wrapping at 256: 57 s of booting at the measured ~11 ms of firmware cost per sector would be",
      "   -- ~5000 sectors if the firmware were the only cost, and the point of the count is to tell that",
      '   -- apart from "DOS is issuing far more reads than expected".',
      "   signal wr_req_cnt, rd_req_cnt, blk_wr_cnt : unsigned(7 downto 0) := (others => '0');",
      "   signal blk_ack_cnt         : unsigned(15 downto 0) := (others => '0');",
      "   -- DIAG-PROBE end") -join $nl
    $decl_old = "   signal wr_req_cnt, rd_req_cnt, blk_wr_cnt, blk_ack_cnt : unsigned(7 downto 0) := (others => '0');"

    $body_new = @(
      "         -- DIAG-PROBE begin (DIAGNOSTIC BUILD ONLY): count vdrive 2 (the hard disk) instead of",
      "         -- vdrive 0 (floppy A). Original lines used blk_wr(0) / blk_ack(0) throughout.",
      "         blkwr_q <= blk_wr(2);   blkack_q <= blk_ack(2);",
      "         if mgmt_req(7) = '1' and mreq7_q = '0' then wr_req_cnt <= wr_req_cnt + 1; end if;",
      "         if mgmt_req(6) = '1' and mreq6_q = '0' then rd_req_cnt <= rd_req_cnt + 1; end if;",
      "         if blk_wr(2)   = '1' and blkwr_q = '0' then blk_wr_cnt <= blk_wr_cnt + 1; end if;",
      "         if blk_ack(2)  = '1' and blkack_q = '0' then blk_ack_cnt <= blk_ack_cnt + 1; end if;",
      "         -- DIAG-PROBE end") -join $nl
    $body_old = @(
      "         blkwr_q <= blk_wr(0);   blkack_q <= blk_ack(0);",
      "         if mgmt_req(7) = '1' and mreq7_q = '0' then wr_req_cnt <= wr_req_cnt + 1; end if;",
      "         if mgmt_req(6) = '1' and mreq6_q = '0' then rd_req_cnt <= rd_req_cnt + 1; end if;",
      "         if blk_wr(0)   = '1' and blkwr_q = '0' then blk_wr_cnt <= blk_wr_cnt + 1; end if;",
      "         if blk_ack(0)  = '1' and blkack_q = '0' then blk_ack_cnt <= blk_ack_cnt + 1; end if;") -join $nl

    $keys_new = '   dbg_keys_o      <= std_logic_vector(blk_ack_cnt);                                -- DIAG-PROBE hdd= : hard-disk (vdrive 2) block acks, full 16 bits (was: std_logic_vector(blk_ack_cnt) & std_logic_vector(blk_wr_cnt), "blk=" for drive A)'
    $keys_old = '   dbg_keys_o      <= std_logic_vector(blk_ack_cnt) & std_logic_vector(blk_wr_cnt); -- blk=  : {block acks, block writes} for drive A'

    $t = $t.Replace($decl_new, $decl_old)
    $t = $t.Replace($body_new, $body_old)
    $t = $t.Replace($keys_new, $keys_old)
    return $t
}

Edit-File 'CORE/m2m-rom/m2m-rom.asm' {
    param($t)
    $t = $t.Replace('DBG_STR_6       .ASCII_W " vga="        ; DIAG-PROBE (was: " bist=")', 'DBG_STR_6       .ASCII_W " bist="')
    $t = $t.Replace('DBG_STR_7       .ASCII_W " ctl="        ; DIAG-PROBE (was: " req=")',  'DBG_STR_7       .ASCII_W " req="')
    $t = $t.Replace('DBG_STR_8       .ASCII_W " hdd="        ; DIAG-PROBE (was: " blk=")',  'DBG_STR_8       .ASCII_W " blk="')
    return $t
}

# nothing tagged may survive
$files = @('M2M/vhdl/top_mega65-r6.vhd','CORE/vhdl/mega65.vhd','CORE/vhdl/main.vhd','CORE/m2m-rom/m2m-rom.asm') |
         ForEach-Object { Join-Path $root $_ }
$left = Select-String -Path $files -Pattern 'DIAG-PROBE'
if ($left -and -not $WhatIf) {
    Write-Output "WARNING: DIAG-PROBE tags still present, remove them by hand:"
    $left | ForEach-Object { Write-Output ("  " + $_.Path + ":" + $_.LineNumber + ": " + $_.Line.Trim()) }
    exit 1
}
Write-Output "files changed: $changed"
