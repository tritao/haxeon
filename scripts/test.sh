#!/usr/bin/env bash
# The test suites: a mode of tests/suites.txt, which lists them in order with how they are scheduled.
#
#   scripts/test.sh [quick|wave|ci|full] [--gate] [--jobs N] [--only NAME,...] [--list]
#
#   quick  the NUL guard, whole-tree type check, default driver, and UI Showcase builds on HL/Wasm32/Wasm GC
#   wave   quick, then the driver again with --check-reuse (adds the warm-edit rebuilds and the reuse comparisons), the Wasm
#          backend script, the strict self-hosting fixed-point, equality and embedding checks and the external-tool build
#   ci     what CI runs, and the default
#   full   all three, each suite once
#
# --gate is the run a report quotes: it refuses a tree with tracked changes (GATE_ALLOW_DIRTY=1 records "dirty" instead), stops if
# the native runtime or the prebuilt tools fail to build, runs 4 jobs unless told otherwise, and writes its logs and summary.txt, whose
# lines are what a report quotes, to out/gate/<commit>-<mode>-<time>/ (without it, out/test/<time>-<mode>/). TEST_JOBS or --jobs sets
# the job count (default 16 without --gate); SKIP_FORMAT_CHECK=1 skips the format check. Every suite runs even when an earlier one
# fails; the exit code is 0 only if every suite that ran passed. Temporary files go to a directory of the run's own, removed after it.
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/.." && pwd)
# The suites run on a session bus of their own with no services to start on demand (tests/dbus-session.conf), wherever they run.
# On a bus where the desktop services are installed but not running, as GLib starts for each Xvfb display on CI, GTK starts the
# desktop portal for each window, which waits out D-Bus's 25-second timeout for a keyring before the window appears.
if [[ $(uname -s) == Linux && -z ${HAXEON_TEST_BUS:-} ]] && command -v dbus-run-session >/dev/null; then
	export HAXEON_TEST_BUS=1
	exec dbus-run-session --config-file="$root_dir/tests/dbus-session.conf" -- "$0" "$@"
fi
mode=ci
case ${1:-} in quick | wave | ci | full) mode=$1 && shift ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export TMPDIR="$work"
# scripts/haxeon runs on the checkout-built HashLink, so it is built first (a no-op when it is up to date).
"$root_dir/scripts/build-native.sh" >/dev/null
"$root_dir/scripts/haxeon" dev test "$mode" "$@"
