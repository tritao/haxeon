#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-flush-scan.XXXXXX")
trap 'rm -rf "$work"' EXIT
"${CC:-cc}" -O2 -Wall -I"$root/vendor/hashlink/src" "$root/tests/native/gc_flush_scan.c" -o "$work/flush-scan"
"$work/flush-scan"
