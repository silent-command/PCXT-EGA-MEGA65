#!/usr/bin/env python3
"""Build the PCXT-EGA for MEGA65 release folder and zip.

Usage:  python3 tools/make_release.py [--version vX.Y] [--cor out/pcxt-ega-r6.cor]
                                      [--with-hd-image] [--out release]

Produces release/PCXT-EGA-MEGA65-<version>/ containing
  pcxt-ega-r6.cor          the core (flash into a MEGA65 R6 core slot)
  m2m/m2mcfg               settings file (OPTM_SIZE bytes of 0xFF = defaults)
  pcxt/pcxt.rom            system BIOS (upstream SW/ROMs/pcxt_pcxt31.rom, GPL)
  pcxt/README.txt          what else goes into /pcxt and where to get it
  pcxt/bios-hd-floppy/     8088_bios XT build + XTIDE: alternative BIOS with
                           1.2 MB / 1.44 MB floppy support (GPL)
  pcxt/freedos.vhd         only with --with-hd-image (from upstream hd_image.zip)
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
    ap.add_argument("--cor", default=str(ROOT / "out" / "pcxt-ega-r6.cor"))
    ap.add_argument("--out", default=str(ROOT / "release"))
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
    (rel / "m2m" / "m2mcfg").write_bytes(b"\xff" * optm_size())

    bios = UPSTREAM / "SW" / "ROMs" / "pcxt_pcxt31.rom"
    if bios.is_file():
        shutil.copy2(bios, rel / "pcxt" / "pcxt.rom")
    else:
        print("warning: upstream pcxt_pcxt31.rom not found (submodule not checked out?)")

    # alternative system BIOS with high-density floppy support (GPL): the user
    # copies both files over /pcxt/pcxt.rom and /pcxt/xtide.rom
    hd = rel / "pcxt" / "bios-hd-floppy"
    hd.mkdir()
    for src in ("pcxt-xt.rom", "xtide.rom"):
        shutil.copy2(ROOT / "sdcard" / "bios" / src, hd / src)

    if a.with_hd_image:
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
