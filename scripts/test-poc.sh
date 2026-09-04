#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
    echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
    exit 1
fi

mkdir -p "$root_dir/out"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run TestMain

run_program() {
    local name=$1
    local expected=$2
    local source_file="$root_dir/tests/programs/$name.hx"
    local output="$root_dir/out/$name.hl"
    "$haxe" --cwd "$root_dir" -cp src --run Main "$source_file" "$output"

    set +e
    LD_LIBRARY_PATH="$root_dir/.tools/hashlink" "$hl" "$output"
    local status=$?
    set -e
    if [[ $status -ne $expected ]]; then
        echo "$name: expected exit $expected, got $status" >&2
        exit 1
    fi
    echo "PASS: $name source compiled and executed (exit $expected)"
}

run_program add 42
run_program function-call 42
run_program bool-if 42
run_program fib 55
