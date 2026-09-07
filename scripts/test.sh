#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/vendor/hashlink/hl"
test_classpaths=(-cp src -cp tests -cp tests/compiler -cp tests/runtime -cp tests/tooling)

make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null

if [[ ${SKIP_FORMAT_CHECK:-0} != 1 ]]; then
	"$root_dir/scripts/format.sh" --check
fi

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

"$root_dir/tests/differential/run.sh"

"$haxe" --cwd "$root_dir" -cp tests --run driver.TestDriver --root "$root_dir" --suite compiler
exception_output="$root_dir/out/exception.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ExceptionMain "$exception_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$exception_output"
exception_status=$?
set -e
if [[ $exception_status -ne 42 ]]; then
	echo "exception compatibility: expected exit 42, got $exception_status" >&2
	exit 1
fi
echo "PASS: exceptions can be chained, thrown, caught, and inspected (exit 42)"
ereg_output="$root_dir/out/ereg.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ERegMain "$ereg_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$ereg_output"
ereg_status=$?
set -e
if [[ $ereg_status -ne 42 ]]; then
	echo "EReg compatibility: expected exit 42, got $ereg_status" >&2
	exit 1
fi
echo "PASS: regex literals and EReg operations executed (exit 42)"
list_output="$root_dir/out/list.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ListMain "$list_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$list_output"
list_status=$?
set -e
if [[ $list_status -ne 42 ]]; then
	echo "List compatibility: expected exit 42, got $list_status" >&2
	exit 1
fi
echo "PASS: Array-backed List insertion and iteration executed (exit 42)"
array_splice_output="$root_dir/out/array-splice.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ArraySpliceMain "$array_splice_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$array_splice_output"
array_splice_status=$?
set -e
if [[ $array_splice_status -ne 42 ]]; then
	echo "Array.splice compatibility: expected exit 42, got $array_splice_status" >&2
	exit 1
fi
echo "PASS: Array.splice mutation and removed values executed (exit 42)"
reflect_methods_output="$root_dir/out/reflect-methods.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ReflectMethodsMain "$reflect_methods_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$reflect_methods_output"
reflect_methods_status=$?
set -e
if [[ $reflect_methods_status -ne 42 ]]; then
	echo "Reflect.compareMethods compatibility: expected exit 42, got $reflect_methods_status" >&2
	exit 1
fi
echo "PASS: Reflect.compareMethods preserves static and bound method identity (exit 42)"
null_reference_output="$root_dir/out/null-reference.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run NullReferenceMain "$null_reference_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$null_reference_output"
null_reference_status=$?
set -e
if [[ $null_reference_status -ne 42 ]]; then
	echo "nullable-reference compatibility: expected exit 42, got $null_reference_status" >&2
	exit 1
fi
echo "PASS: null coerces to reference-like types while primitives remain strict (exit 42)"
"$haxe" --cwd "$root_dir" -cp tests --run driver.TestDriver --root "$root_dir" --suite tooling,runtime
stdlib_output="$root_dir/out/stdlib.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run StdlibMain "$stdlib_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$stdlib_output"
stdlib_status=$?
set -e
if [[ $stdlib_status -ne 42 ]]; then
	echo "vendored stdlib: expected exit 42, got $stdlib_status" >&2
	exit 1
fi
echo "PASS: vendored stdlib compiled and executed (exit 42)"

"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run UtestDiscoveryMain
pos_initial_output="$root_dir/out/pos-initial.hl"
pos_edited_output="$root_dir/out/pos-edited.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run PosInfosMain "$pos_initial_output" "$pos_edited_output"
for position_fixture in "$pos_initial_output:4" "$pos_edited_output:5"; do
	position_output=${position_fixture%:*}
	position_expected=${position_fixture##*:}
	set +e
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$position_output"
	position_status=$?
	set -e
	if [[ $position_status -ne $position_expected ]]; then
		echo "PosInfos: expected line $position_expected, got $position_status" >&2
		exit 1
	fi
done
echo "PASS: PosInfos call-site lines refresh after source edits"
utest_output="$root_dir/out/utest-basic.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run UtestMain "$utest_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$utest_output"
utest_status=$?
set -e
if [[ $utest_status -ne 0 ]]; then
	echo "utest compatibility: expected exit 0, got $utest_status" >&2
	exit 1
fi
echo "PASS: utest-compatible assertions and runner executed (exit 0)"
utest_failure_output="$root_dir/out/utest-failure.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run UtestMain "$utest_failure_output" "tests/programs/utest-failure.hx"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$utest_failure_output"
utest_failure_status=$?
set -e
if [[ $utest_failure_status -ne 5 ]]; then
	echo "utest failure reporting: expected exit 5, got $utest_failure_status" >&2
	exit 1
fi
echo "PASS: utest-compatible runner reports assertion failures (exit 5)"
utest_hook_failure_output="$root_dir/out/utest-hook-failure.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run UtestMain "$utest_hook_failure_output" "tests/programs/utest-hook-failure.hx"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$utest_hook_failure_output"
utest_hook_failure_status=$?
set -e
if [[ $utest_hook_failure_status -ne 2 ]]; then
	echo "utest hook failure reporting: expected exit 2, got $utest_hook_failure_status" >&2
	exit 1
fi
echo "PASS: utest-compatible lifecycle hook failures are isolated (exit 2)"
"$haxe" --cwd "$root_dir" "$root_dir/tests/hxml/repl-test.hxml"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$root_dir/out/repl-test.hl"
repl_status=$?
set -e
if [[ $repl_status -ne 0 ]]; then
	echo "REPL: expected exit 0, got $repl_status" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" "$root_dir/tests/hxml/plugin-test.hxml"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$root_dir/out/plugin-test.hl" "$root_dir/out/plugin-runtime.hl"
plugin_status=$?
set -e
if [[ $plugin_status -ne 0 ]]; then
	echo "plugin workload: expected exit 0, got $plugin_status" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" "$root_dir/tests/hxml/static-init-order-test.hxml"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$root_dir/out/static-init-order-test.hl"
static_init_status=$?
set -e
if [[ $static_init_status -ne 0 ]]; then
	echo "static initializer order: expected exit 0, got $static_init_status" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" "$root_dir/tests/hxml/instance-initializer-test.hxml"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$root_dir/out/instance-initializer-test.hl"
instance_initializer_status=$?
set -e
if [[ $instance_initializer_status -ne 0 ]]; then
	echo "instance initializer invalidation: expected exit 0, got $instance_initializer_status" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" -cp tests --run driver.TestDriver --root "$root_dir" --suite programs


object_output="$root_dir/out/object.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ObjectMain "$object_output"
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
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ClosureMain "$closure_output"
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
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run InstanceClosureMain "$instance_closure_output"
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
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run CollectionMain "$collection_output"
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
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ArrayMain "$array_output"
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
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ArrayAllocMain "$compiler_array_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$compiler_array_output"
compiler_array_status=$?
set -e
if [[ $compiler_array_status -ne 47 ]]; then
	echo "compiler array: expected exit 47, got $compiler_array_status" >&2
	exit 1
fi
echo "PASS: compiler-owned Int/Float/Bool/String array allocation executed (exit 47)"

value_struct_output="$root_dir/out/value-struct.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ValueStructMain "$value_struct_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$value_struct_output"
value_struct_status=$?
set -e
if [[ $value_struct_status -ne 42 ]]; then
	echo "value struct: expected exit 42, got $value_struct_status" >&2
	exit 1
fi
echo "PASS: HSTRUCT value and HPACKED embedded field executed (exit 42)"

string_output="$root_dir/out/string.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run StringMain "$string_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$string_output"
string_status=$?
set -e
if [[ $string_status -ne 42 ]]; then
	echo "string concat: expected exit 42, got $string_status" >&2
	exit 1
fi
echo "PASS: compiler-owned string concatenation executed (exit 42)"

import_output="$root_dir/out/import.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ImportMain "$import_output"
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
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ImportClassMain "$import_class_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$import_class_output"
import_class_status=$?
set -e
if [[ $import_class_status -ne 42 ]]; then
	echo "imported class: expected exit 42, got $import_class_status" >&2
	exit 1
fi
echo "PASS: imported nominal class executed (exit 42)"

namespace_output="$root_dir/out/namespace.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run NamespaceMain "$namespace_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$namespace_output"
namespace_status=$?
set -e
if [[ $namespace_status -ne 42 ]]; then
	echo "qualified nominal namespace: expected exit 42, got $namespace_status" >&2
	exit 1
fi
echo "PASS: qualified nominal namespaces executed (exit 42)"

instance_module_output="$root_dir/out/instance-module.hl"
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run InstanceModuleMain "$instance_module_output"
set +e
LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$instance_module_output"
instance_module_status=$?
set -e
if [[ $instance_module_status -ne 42 ]]; then
	echo "incremental instance class: expected exit 42, got $instance_module_status" >&2
	exit 1
fi
echo "PASS: incremental instance class executed (exit 42)"

"$haxe" --cwd "$root_dir" "$root_dir/tests/hxml/static-field-test.hxml"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$root_dir/out/static-field-test.hl"
static_field_status=$?
set -e
if [[ $static_field_status -ne 0 ]]; then
	echo "static field runtime: expected exit 0, got $static_field_status" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ModuleMain "$root_dir/out/modules.hl"
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
"$haxe" --cwd "$root_dir" "${test_classpaths[@]}" --run ArrayBoundsMain "$bounds_output"
set +e
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$bounds_output" >/dev/null 2>&1
bounds_status=$?
set -e
if [[ $bounds_status -eq 0 ]]; then
	echo "array bounds: out-of-bounds read unexpectedly succeeded" >&2
	exit 1
fi
echo "PASS: HashLink array bounds check rejected invalid index"
