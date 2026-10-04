#!/usr/bin/env python3
"""Build the PCXT-EGA for MEGA65 release folder and zip.

Usage:  python3 tools/make_release.py [--version vX.Y] [--cor out/pcxt-ega-r6.cor]
                                      [--hd-image FILE] [--out release]

Produces release/PCXT-EGA-MEGA65-<version>/ containing
  pcxt-ega-r6.cor          the core for a MEGA65 R6 (tested)
  pcxt-ega-r3.cor          the same core for an R3 (one field report, see the README)
  m2m/m2mcfg               settings file (OPTM_SIZE bytes of 0xFF = defaults)
  m2m/hdmount              where the core remembers the hard disk image (128
                           zero bytes = nothing remembered, docs/hd-mount-memory.md)
  pcxt/README.txt          what else goes into /pcxt and where to get it
  pcxt/joytest.img         JOYTEST.COM + SETJOY.COM (game port test, BIOS bit)
  pcxt/netdisk.img         NE1000 packet driver + mTCP: NET.BAT, DHCP, FTP...
  pcxt/roms/               every system BIOS option, with a README
  pcxt/pcxt.rom            the default BIOS (8088 BIOS) already in place
  pcxt/xtide.rom           the XTIDE option ROM that goes with it
  pcxt/freedos.vhd         only with --hd-image FILE (the master is
                           ../freedos-clean.vhd: upstream image cleaned with
                           clean-hd-image.py plus FASTFREE.COM, see
                           tools/fastfree) or --with-hd-image
  README.md                installation, menu, keyboard, limitations
  LICENSE, VERSION.txt
and release/PCXT-EGA-MEGA65-<version>.zip.

The EGA BIOS (ega_bios.rom) is an IBM ROM dump and is NOT included; the user
builds it with the upstream script (see pcxt/README.txt).
"""
import argparse, os, re, shutil, subprocess, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / "CORE" / "PCXT-EGA_MiSTer"


def optm_size():
    text = (ROOT / "CORE" / "vhdl" / "config.vhd").read_text(errors="replace")
    m = re.search(r"constant OPTM_SIZE\s*:\s*natural\s*:=\s*(\d+)", text)
    if not m:
        sys.exit("OPTM_SIZE not found in CORE/vhdl/config.vhd")
    return int(m.group(1))


def core_version():
    text = (ROOT / "CORE" / "vhdl" / "config.vhd").read_text(errors="replace")
    m = re.search(r'constant CORENAME\s*:\s*string\s*:=\s*"([^"]+)"', text)
    if not m:
        return "v0.0"
    v = re.search(r"V(\d+(?:\.\d+)*)", m.group(1))
    return "v" + v.group(1) if v else "v0.0"


def git_describe():
    # "dirty" is judged ignoring CR/LF differences: the tree is checked out
    # with CRLF on Windows and this script runs under WSL, whose git would
    # otherwise report every CRLF file as modified.
    try:
        g = ["git", "-C", str(ROOT)]
        d = subprocess.check_output(g + ["describe", "--always", "--tags"], text=True).strip()
        clean = (subprocess.call(g + ["diff", "--quiet", "--ignore-cr-at-eol", "--ignore-submodules=dirty"]) == 0 and
                 subprocess.call(g + ["diff", "--quiet", "--cached", "--ignore-cr-at-eol", "--ignore-submodules=dirty"]) == 0)
        return d if clean else d + "-dirty"
    except Exception:
        return "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=core_version())
    ap.add_argument("--cor", default=str(ROOT / "out" / "pcxt-ega-r6.cor"),
                    help="the R6 core, the one that is tested")
    ap.add_argument("--cor-r3", default=str(ROOT / "out" / "pcxt-ega-r3.cor"),
                    help="the R3 core; omitted from the package if absent")
    ap.add_argument("--out", default=str(ROOT / "release"))
    ap.add_argument("--hd-image", metavar="FILE",
                    help="copy this hard disk image in as pcxt/freedos.vhd")
    ap.add_argument("--with-hd-image", action="store_true",
                    help="extract upstream games/PCXT/hd_image.zip into pcxt/freedos.vhd")
    a = ap.parse_args()

    cor = Path(a.cor)
    if not cor.is_file():
        sys.exit(f"core file not found: {cor}")
    name = f"PCXT-EGA-MEGA65-{a.version}"
    rel = Path(a.out) / name
    if rel.exists():
        shutil.rmtree(rel)
    (rel / "m2m").mkdir(parents=True)
    (rel / "pcxt").mkdir()

    shutil.copy2(cor, rel / "pcxt-ega-r6.cor")
    cor_r3 = Path(a.cor_r3)
    if cor_r3.is_file():
        shutil.copy2(cor_r3, rel / "pcxt-ega-r3.cor")
    else:
        print(f"note: no R3 core at {cor_r3}, packaging R6 only")
    (rel / "m2m" / "m2mcfg").write_bytes(b"\xff" * optm_size())
    # the firmware can rewrite this file but not create it (hdmount.asm)
    (rel / "m2m" / "hdmount").write_bytes(bytes(128))

    # Every system BIOS in one place, and the default already in position so the
    # card works as shipped. The default is the 8088 BIOS with the XTIDE option
    # ROM beside it: that pair gives both large hard disks (XTIDE) and 1.2 /
    # 1.44 MB floppies, including the MEGA65's internal drive, which the Turbo XT
    # BIOS cannot do. Swapping default is a file copy, see pcxt/roms/README.txt.
    roms = rel / "pcxt" / "roms"
    roms.mkdir()
    shutil.copy2(ROOT / "sdcard" / "bios" / "pcxt-xt.rom", roms / "8088-bios-xt.rom")
    shutil.copy2(ROOT / "sdcard" / "bios" / "xtide.rom", roms / "xtide.rom")
    turbo = UPSTREAM / "SW" / "ROMs" / "pcxt_pcxt31.rom"
    if turbo.is_file():
        shutil.copy2(turbo, roms / "turbo-xt-3.1-with-xtide.rom")
    else:
        print("warning: upstream pcxt_pcxt31.rom not found (submodule not checked out?)")

    # the default the core loads at start-up
    shutil.copy2(roms / "8088-bios-xt.rom", rel / "pcxt" / "pcxt.rom")
    shutil.copy2(roms / "xtide.rom", rel / "pcxt" / "xtide.rom")

    (roms / "README.txt").write_text(
        "/pcxt/roms - the system BIOS options\n"
        "====================================\n\n"
        "The core loads /pcxt/pcxt.rom at start-up, and /pcxt/xtide.rom after it\n"
        "if it is present. This release ships with the first option below already\n"
        "in place, so you do not have to do anything.\n\n"
        "  8088-bios-xt.rom  Sergey Kiselev's 8088 BIOS, XT build (GPL v3).\n"
        "                    THE DEFAULT, copied to /pcxt/pcxt.rom. Needs\n"
        "                    xtide.rom beside it, which is also already in place.\n"
        "                    Large hard disks through XTIDE, and 1.2 / 1.44 MB\n"
        "                    floppies - which the other BIOS cannot do, and which\n"
        "                    the MEGA65's internal drive needs.\n"
        "                    https://github.com/skiselev/8088_bios\n\n"
        "  xtide.rom         XTIDE Universal BIOS (GPL v2), the hard disk option\n"
        "                    ROM. Loaded from /pcxt/xtide.rom.\n"
        "                    https://www.xtideuniversalbios.org/\n\n"
        "  turbo-xt-3.1-with-xtide.rom\n"
        "                    Super PC/Turbo XT BIOS v3.1 with XTIDE built in\n"
        "                    (GPL). Large hard disks, but NO high-density floppy\n"
        "                    support. To use it instead:\n"
        "                      copy roms\\turbo-xt-3.1-with-xtide.rom  pcxt.rom\n"
        "                      del  xtide.rom\n"
        "                    https://github.com/virtualxt/pcxtbios\n\n"
        "The EGA BIOS is a separate ROM and is not here: see ../README.txt.\n",
        encoding="ascii")

    # joystick test / BIOS equipment-bit floppy (see README, joystick note)
    shutil.copy2(ROOT / "tools" / "joytest" / "joytest.img", rel / "pcxt" / "joytest.img")
    # networking kit: Crynwr NE1000 packet driver + mTCP (GPL), see README, Network
    shutil.copy2(ROOT / "tools" / "dosnet" / "netdisk.img", rel / "pcxt" / "netdisk.img")

    if a.hd_image:
        src = Path(a.hd_image)
        if not src.is_file():
            sys.exit(f"hard disk image not found: {src}")
        shutil.copy2(src, rel / "pcxt" / "freedos.vhd")
    elif a.with_hd_image:
        z = UPSTREAM / "games" / "PCXT" / "hd_image.zip"
        if not z.is_file():
            sys.exit(f"hd_image.zip not found: {z}")
        with zipfile.ZipFile(z) as zf:
            imgs = [n for n in zf.namelist() if n.lower().endswith((".vhd", ".img"))]
            if not imgs:
                sys.exit("no .vhd/.img inside hd_image.zip")
            with zf.open(imgs[0]) as src, open(rel / "pcxt" / "freedos.vhd", "wb") as dst:
                shutil.copyfileobj(src, dst)

    shutil.copy2(ROOT / "docs" / "release" / "README.md", rel / "README.md")
    shutil.copy2(ROOT / "docs" / "release" / "pcxt-README.txt", rel / "pcxt" / "README.txt")
    shutil.copy2(ROOT / "LICENSE", rel / "LICENSE")
    (rel / "VERSION.txt").write_text(
        f"PCXT-EGA for MEGA65 {a.version}\nbuild: {git_describe()}\ncore: {cor.name}\n"
        f"settings file: {optm_size()} bytes\n")

    zpath = Path(a.out) / f"{name}.zip"
    if zpath.exists():
        zpath.unlink()
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as zf:
        for p in sorted(rel.rglob("*")):
            if p.is_file():
                zf.write(p, p.relative_to(rel.parent))
    print(f"release: {rel}")
    print(f"zip:     {zpath}  ({zpath.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
