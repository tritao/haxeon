#!/usr/bin/env bash
# The gate: the suites in a fixed configuration, with a summary that reports quote.
#
#   scripts/gate.sh quick|wave|full [jobs]
#
#   quick  the NUL guard, whole-tree type check, default driver, and UI Showcase builds on HL/Wasm32/Wasm GC
#   wave   quick, then the driver again with HAXEON_CHECK_REUSE=1 (adds the warm-edit rebuilds and the reuse comparisons), the Wasm
#          backend script (a broken Wasm fixture once reached main because no gate ran it), the strict self-hosting
#          fixed-point, equality and embedding checks
#          and the external-tool build (a tool outside the tree links the compiler sources through common.hxml)
#   full   wave and every suite scripts/test.sh runs, each once
#
# The modes are groups of tests/suites.txt, run by `scripts/haxeon dev test <mode> --gate`. The native runtime and the prebuilt tools
# are built once, first; if that fails the gate stops. The tracked tree must be clean (GATE_ALLOW_DIRTY=1 records "dirty" instead of
# refusing). Every suite runs even when an earlier one fails. Results go to out/gate/<commit>-<mode>-<time>/: a log per suite and
# summary.txt, whose lines are what a gate report quotes. The exit code is 0 only if every suite passed.
set -euo pipefail
mode=${1:?usage: gate.sh quick|wave|full [jobs]}
jobs=${2:-4}
case "$mode" in quick | wave | full) ;; *) echo "unknown mode: $mode" >&2; exit 2 ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gate.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export TMPDIR="$work"
"$root/scripts/build-native.sh" >/dev/null
"$root/scripts/haxeon" dev test "$mode" --gate --jobs "$jobs"
