#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"
out_dir="$root_dir/out/differential"
runtime_library_variable=LD_LIBRARY_PATH
if [[ "$(uname -s)" == "Darwin" ]]; then
	runtime_library_variable=DYLD_LIBRARY_PATH
fi

run_hl() {
	local library_path=$1
	shift
	local existing="${!runtime_library_variable:-}"
	if [[ -n "$existing" ]]; then
		library_path="$library_path:$existing"
	fi
	env "$runtime_library_variable=$library_path" "$hl" "$@"
}

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

"$root_dir/scripts/build-native.sh" >/dev/null
mkdir -p "$out_dir"

# Compile with haxeon: the HashLink build scripts/test.sh provides, else `haxe --run Main`.
realtime_compile() {
	if [[ -n ${HAXEON_MAIN_HL:-} && -f $HAXEON_MAIN_HL ]]; then
		(cd "$root_dir" && run_hl "$root_dir/out:$root_dir/.tools/hashlink" "$HAXEON_MAIN_HL" "$1" "$2")
	else
		"$haxe" --cwd "$root_dir" -cp src --run Main "$1" "$2"
	fi
}

run_case() {
	local name=$1
	local expected_status=${2:-}
	local reference_target=${3:-hl}
	local official_source="$root_dir/tests/differential/$name.official.hx"
	local realtime_source="$root_dir/tests/differential/$name.realtime.hx"
	local official_output="$out_dir/$name.official.hl"
	local realtime_output="$out_dir/$name.realtime.hl"
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official.XXXXXX")
	trap 'rm -rf "$official_dir"' RETURN
	cp "$official_source" "$official_dir/Main.hx"

	"$haxe" -cp "$official_dir" -main Main -hl "$official_output"
	realtime_compile "$realtime_source" "$realtime_output" >/dev/null

	set +e
	local official_log="$out_dir/$name.official.log"
	local realtime_log="$out_dir/$name.realtime.log"
	if [[ "$reference_target" == interp ]]; then
		"$haxe" -cp "$official_dir" -main Main --interp >"$official_log" 2>&1
	else
		run_hl "$root_dir/.tools/hashlink" "$official_output" >"$official_log" 2>&1
	fi
	local official_status=$?
	run_hl "$root_dir/out:$root_dir/.tools/hashlink" "$realtime_output" >"$realtime_log" 2>&1
	local realtime_status=$?
	set -e

	if [[ -n "$expected_status" && $official_status -ne $expected_status ]]; then
		echo "$name: reference fixture expected exit $expected_status, got $official_status" >&2
		cat "$official_log" >&2
		exit 1
	fi
	if [[ $official_status -ne $realtime_status ]]; then
		echo "$name: official=$official_status realtime=$realtime_status" >&2
		echo "--- official output ---" >&2
		cat "$official_log" >&2 || true
		echo "--- realtime output ---" >&2
		cat "$realtime_log" >&2 || true
		exit 1
	fi
	if ! cmp -s "$official_log" "$realtime_log"; then
		echo "$name: observable output differs" >&2
		diff -u "$official_log" "$realtime_log" >&2 || true
		exit 1
	fi
	echo "PASS: $name official and realtime behavior agree (exit $official_status)"
}

run_compile_failure() {
	local name=$1
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official-failure.XXXXXX")
	cp "$root_dir/tests/differential/$name.official.hx" "$official_dir/Main.hx"
	set +e
	"$haxe" -cp "$official_dir" -main Main -hl "$out_dir/$name.official.hl" >/dev/null 2>&1
	local official_status=$?
	realtime_compile "$root_dir/tests/differential/$name.realtime.hx" "$out_dir/$name.realtime.hl" >/dev/null 2>&1
	local realtime_status=$?
	set -e
	rm -rf "$official_dir"
	if [[ $official_status -eq 0 || $realtime_status -eq 0 ]]; then
		echo "$name: expected both compilers to reject source (official=$official_status realtime=$realtime_status)" >&2
		exit 1
	fi
	echo "PASS: $name official and realtime compilers both reject invalid source"
}

# Cases are independent; run them concurrently and report in order.
pids=()
logs=()
in_background() {
	local log="$out_dir/$2.run.log"
	("$@") >"$log" 2>&1 &
	pids+=($!)
	logs+=("$log")
}
in_background run_case arithmetic
in_background run_case fibonacci
in_background run_case control-flow
in_background run_case nullable
in_background run_case observable-output
in_background run_case compiler-audit
in_background run_case exception-capture-order 0
# Haxe 4.3.7's HL backend loses the final local write before this throw;
# its interpreter preserves it. Keep this case against the interpreter oracle.
in_background run_case exception-loop-control 0 interp
in_background run_case assignment-evaluation-order 0
in_background run_compile_failure type-error
status=0
for index in "${!pids[@]}"; do
	wait "${pids[$index]}" || status=1
	cat "${logs[$index]}"
done
exit "$status"
