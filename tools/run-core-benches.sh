#!/usr/bin/env bash
# Run all four regression suites of the pinned PCXT-EGA_MiSTer submodule.
# Run from WSL. Extra arguments are passed to every suite (e.g. -n).
set -uo pipefail
core=$(cd "$(dirname "$0")/../CORE/PCXT-EGA_MiSTer" && pwd)
rc=0
for suite in KFPC-XT video 8088 sound; do
    echo "=== $suite ==="
    bash "$core/rtl/$suite/TESTBENCH/run_tests.sh" "$@" || rc=1
    echo
done
exit $rc
