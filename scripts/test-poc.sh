#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/vendor/hashlink/hl"

make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null

"$root_dir/scripts/format.sh" --check

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
    echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
    exit 1
fi

mkdir -p "$root_dir/out"
cc -shared -fPIC -DHL_NAME\(n\)=realtime_##n \
	-I "$root_dir/vendor/hashlink/src" \
	"$root_dir/native/runtime.c" \
	-L "$root_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$root_dir/vendor/hashlink" \
	-o "$root_dir/out/realtime_runtime.hdll"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run TestMain
"$haxe" --cwd "$root_dir" -cp src -cp tests --run LanguageServiceMain
"$haxe" --cwd "$root_dir" "$root_dir/repl-test.hxml"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$root_dir/out/repl-test.hl"
repl_status=$?
set -e
if [[ $repl_status -ne 0 ]]; then
	echo "REPL: expected exit 0, got $repl_status" >&2
	exit 1
fi

run_program() {
    local name=$1
    local expected=$2
    local source_file="$root_dir/tests/programs/$name.hx"
    local output="$root_dir/out/$name.hl"
    "$haxe" --cwd "$root_dir" -cp src --run Main "$source_file" "$output"

    set +e
	LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$output"
    local status=$?
    set -e
    if [[ $status -ne $expected ]]; then
        echo "$name: expected exit $expected, got $status" >&2
        exit 1
    fi
    echo "PASS: $name source compiled and executed (exit $expected)"
}

run_program add 42
run_program call-many 42
run_program function-call 42
run_program function-value 42
run_program lambda 42
run_program captured-lambda 42
run_program trace 42
run_program callback-method 42
run_program name-collision 42
run_program bool-if 42
run_program fib 55
run_program while-arithmetic 42
run_program branch-assignment 42
run_program static-class 42
run_program instance-class 42
run_program default-constructor-class 42
run_program inheritance-class 43
run_program virtual-dispatch 71

object_output="$root_dir/out/object.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ObjectMain "$object_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$object_output"
object_status=$?
set -e
if [[ $object_status -ne 42 ]]; then
	echo "object IR: expected exit 42, got $object_status" >&2
	exit 1
fi
echo "PASS: object allocation and field access executed (exit 42)"

closure_output="$root_dir/out/closure.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ClosureMain "$closure_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$closure_output"
closure_status=$?
set -e
if [[ $closure_status -ne 42 ]]; then
	echo "closure IR: expected exit 42, got $closure_status" >&2
	exit 1
fi
echo "PASS: static closure allocation and invocation executed (exit 42)"

instance_closure_output="$root_dir/out/instance-closure.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run InstanceClosureMain "$instance_closure_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$instance_closure_output"
instance_closure_status=$?
set -e
if [[ $instance_closure_status -ne 42 ]]; then
	echo "instance closure IR: expected exit 42, got $instance_closure_status" >&2
	exit 1
fi
echo "PASS: instance closure capture ABI executed (exit 42)"

collection_output="$root_dir/out/collection.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run CollectionMain "$collection_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$collection_output"
collection_status=$?
set -e
if [[ $collection_status -ne 42 ]]; then
	echo "native collection: expected exit 42, got $collection_status" >&2
	exit 1
fi
echo "PASS: native-backed collection object executed (exit 42)"

array_output="$root_dir/out/array.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ArrayMain "$array_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$array_output"
array_status=$?
set -e
if [[ $array_status -ne 42 ]]; then
	echo "native array: expected exit 42, got $array_status" >&2
	exit 1
fi
echo "PASS: first-class Array<Int> indexing executed (exit 42)"

compiler_array_output="$root_dir/out/compiler-array.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ArrayAllocMain "$compiler_array_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$compiler_array_output"
compiler_array_status=$?
set -e
if [[ $compiler_array_status -ne 45 ]]; then
	echo "compiler array: expected exit 45, got $compiler_array_status" >&2
	exit 1
fi
echo "PASS: compiler-owned Int/Float/String array allocation executed (exit 45)"

import_output="$root_dir/out/import.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ImportMain "$import_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$import_output"
import_status=$?
set -e
if [[ $import_status -ne 42 ]]; then
	echo "package import: expected exit 42, got $import_status" >&2
	exit 1
fi
echo "PASS: package-qualified import executed (exit 42)"

import_class_output="$root_dir/out/import-class.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ImportClassMain "$import_class_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$import_class_output"
import_class_status=$?
set -e
if [[ $import_class_status -ne 42 ]]; then
	echo "imported class: expected exit 42, got $import_class_status" >&2
	exit 1
fi
echo "PASS: imported nominal class executed (exit 42)"

instance_module_output="$root_dir/out/instance-module.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run InstanceModuleMain "$instance_module_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$instance_module_output"
instance_module_status=$?
set -e
if [[ $instance_module_status -ne 42 ]]; then
	echo "incremental instance class: expected exit 42, got $instance_module_status" >&2
	exit 1
fi
echo "PASS: incremental instance class executed (exit 42)"

"$haxe" --cwd "$root_dir" -cp src -cp tests --run ModuleMain "$root_dir/out/modules.hl"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$root_dir/out/modules.hl"
module_status=$?
set -e
if [[ $module_status -ne 42 ]]; then
    echo "modules: expected exit 42, got $module_status" >&2
    exit 1
fi
echo "PASS: incrementally rebuilt multi-module program executed (exit 42)"

bounds_output="$root_dir/out/array-bounds.hl"
"$haxe" --cwd "$root_dir" -cp src -cp tests --run ArrayBoundsMain "$bounds_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$bounds_output" >/dev/null 2>&1
bounds_status=$?
set -e
if [[ $bounds_status -eq 0 ]]; then
	echo "array bounds: out-of-bounds read unexpectedly succeeded" >&2
	exit 1
fi
echo "PASS: HashLink array bounds check rejected invalid index"
