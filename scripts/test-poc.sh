#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"

"$root_dir/scripts/format.sh" --check

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
run_program name-collision 42
run_program bool-if 42
run_program fib 55
run_program while-arithmetic 42
run_program branch-assignment 42
run_program static-class 42
run_program instance-class 42
run_program default-constructor-class 42
run_program inheritance-class 43

object_output="$root_dir/out/object.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ObjectMain "$object_output"
set +e
LD_LIBRARY_PATH="$root_dir/.tools/hashlink" "$hl" "$object_output"
object_status=$?
set -e
if [[ $object_status -ne 42 ]]; then
	echo "object IR: expected exit 42, got $object_status" >&2
	exit 1
fi
echo "PASS: object allocation and field access executed (exit 42)"

instance_module_output="$root_dir/out/instance-module.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run InstanceModuleMain "$instance_module_output"
set +e
LD_LIBRARY_PATH="$root_dir/.tools/hashlink" "$hl" "$instance_module_output"
instance_module_status=$?
set -e
if [[ $instance_module_status -ne 42 ]]; then
	echo "incremental instance class: expected exit 42, got $instance_module_status" >&2
	exit 1
fi
echo "PASS: incremental instance class executed (exit 42)"

"$haxe" --cwd "$root_dir" -cp src -cp tests --run ModuleMain "$root_dir/out/modules.hl"
set +e
LD_LIBRARY_PATH="$root_dir/.tools/hashlink" "$hl" "$root_dir/out/modules.hl"
module_status=$?
set -e
if [[ $module_status -ne 42 ]]; then
    echo "modules: expected exit 42, got $module_status" >&2
    exit 1
fi
echo "PASS: incrementally rebuilt multi-module program executed (exit 42)"
