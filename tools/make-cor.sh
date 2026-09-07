#!/usr/bin/env bash
# Package a Vivado bitstream as a MEGA65 .cor file using the official
# MEGA65 coretool (mega65-tools). Run from WSL.
#
# Usage: tools/make-cor.sh <in.bit> <core name> <core version> <out.cor> [target]
#   target defaults to mega65r6.
#
# M65TOOLS may point at a mega65-tools checkout or release folder containing
# coretool.py; it defaults to the m65tools-* folder next to this repo.
set -euo pipefail

if [ $# -lt 4 ]; then
    echo "usage: $0 <in.bit> <core name> <core version> <out.cor> [target]" >&2
    exit 1
fi
bit=$1; name=$2; version=$3; out=$4; target=${5:-mega65r6}

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${M65TOOLS:-}" ]; then
    M65TOOLS=$(ls -d "$repo_dir"/../m65tools-* 2>/dev/null | head -1 || true)
fi
coretool="$M65TOOLS/coretool.py"
if [ ! -f "$coretool" ]; then
    echo "ERROR: coretool.py not found (M65TOOLS='$M65TOOLS')." >&2
    echo "       Get mega65-tools from https://github.com/MEGA65/mega65-tools" >&2
    exit 1
fi

python3 "$coretool" --no-color --force --build "$out" --target "$target" \
    --bit "$bit" --bit-name "$name" --bit-version "$version"
python3 "$coretool" --no-color --verify "$out"
