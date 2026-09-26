#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"
test_cli_hl=""

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

run_timed() {
	local label=$1
	shift
	local start=$SECONDS
	local status=0

	"$@" || status=$?
	printf 'TIMING: %s: %ss (exit %s)\n' "$label" "$((SECONDS - start))" "$status"
	return "$status"
}

build_native_quietly() {
	"$root_dir/scripts/build-native.sh" >/dev/null
}

run_isolated_integration_batch() {
	local logs_dir
	local test
	local log
	local index
	local status=0
	local -a tests=("$@")
	local -a logs=()
	local -a pids=()

	logs_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-ci-integration.XXXXXX")
	echo "Running isolated integration tests in parallel: ${tests[*]}"
	for test in "${tests[@]}"; do
		log="$logs_dir/$(basename "$test").log"
		logs+=("$log")
		if [[ -n "$test_cli_hl" ]]; then
			HAXEON_HAXE="$root_dir/scripts/test-cli-launcher.sh" HAXEON_REAL_HAXE="$haxe" HAXEON_TEST_CLI_HL="$test_cli_hl" \
				run_timed "$(basename "$test")" bash "$root_dir/$test" >"$log" 2>&1 &
		else
			run_timed "$(basename "$test")" bash "$root_dir/$test" >"$log" 2>&1 &
		fi
		pids+=("$!")
	done

	for index in "${!pids[@]}"; do
		if wait "${pids[$index]}"; then
			:
		else
			status=1
		fi
		cat "${logs[$index]}"
	done
	rm -rf -- "$logs_dir"
	return "$status"
}

run_isolated_integration_group() {
	local integration_jobs=${TEST_JOBS:-16}
	local start
	local -a tests=("$@")
	local -a batch=()

	if ((integration_jobs < 1)); then
		integration_jobs=1
	fi
	if ((integration_jobs > 6)); then
		integration_jobs=6
	fi
	for ((start = 0; start < ${#tests[@]}; start += integration_jobs)); do
		batch=("${tests[@]:start:integration_jobs}")
		run_isolated_integration_batch "${batch[@]}"
	done
}

if [[ ${SKIP_FORMAT_CHECK:-0} != 1 ]]; then
	run_timed format-check "$root_dir/scripts/format.sh" --check
fi

run_timed native-build build_native_quietly
export HAXEON_NATIVE_READY=1
mkdir -p "$root_dir/out"

# Build the compiler entry points and the build tool to HashLink bytecode once. The test driver,
# the differential tests and the Wasm scripts reuse the compilers instead of re-interpreting the
# whole compiler with `haxe --run` for every case (~2 s each, of which compiling takes ~0.2 s),
# and the build tool hashes native inputs under the JIT instead of the interpreter.
mkdir -p "$root_dir/out/test-tools"
prebuilt_compilers=$(mktemp -d "$root_dir/out/test-tools/compilers.XXXXXX")
trap 'rm -rf -- "$prebuilt_compilers"' EXIT
export HAXEON_MAIN_HL="$prebuilt_compilers/haxeon-main.hl"
export HAXEON_COMPILER_HL="$prebuilt_compilers/haxeon-compiler.hl"
prebuilt_build_tool="$prebuilt_compilers/haxeon-build.hl"
build_prebuilt_compilers() {
	local status=0
	"$haxe" --cwd "$root_dir" -cp src -hl "$HAXEON_MAIN_HL" -main Main &
	local main_build=$!
	"$haxe" --cwd "$root_dir" -cp src -hl "$prebuilt_build_tool" -main build.HaxeonBuild &
	local build_tool_build=$!
	"$haxe" --cwd "$root_dir" -cp src -hl "$HAXEON_COMPILER_HL" -main compiler.tools.HaxeonCompiler || status=1
	wait "$main_build" || status=1
	wait "$build_tool_build" || status=1
	return "$status"
}
run_timed prebuilt-compilers build_prebuilt_compilers
run_timed hxi-value-records bash "$root_dir/scripts/test-hxi-value-records.sh"
run_timed messagepack-interop bash "$root_dir/scripts/test-messagepack-interop.sh"

run_timed differential-tests "$root_dir/tests/differential/run.sh"
run_haxeon_build() {
	(cd "$root_dir" && LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		DYLD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$hl" "$prebuilt_build_tool" "$@")
}
run_timed compiler-runtime-tests run_haxeon_build test "${TEST_JOBS:-16}"
# Both Wasm backends: backend-specific checks, then every manifest program against HL's exit codes.
# They run alongside the integration stages below, which never touch Wasm artifacts. (Not alongside
# compiler-runtime-tests: its WasmBackendMain case rewrites the out/wasm-backend-* files they read.)
run_wasm_stages() {
	run_timed wasm-backend bash "$root_dir/scripts/test-wasm-backend.sh"
	run_timed wasm-parity bash "$root_dir/scripts/test-wasm-gc-parity.sh"
	if [[ -n ${WASMTIME:-} || -x "$root_dir/.tools/wasmtime-47.0.0/wasmtime" ]] || command -v wasmtime >/dev/null 2>&1; then
		run_timed wasm-gc-wasmtime bash "$root_dir/scripts/test-wasm-gc-wasmtime.sh"
	else
		echo "Skipping Wasm GC wasmtime checks: Wasmtime 47.0.0 is not installed (set WASMTIME to its executable)"
	fi
}
wasm_log="$prebuilt_compilers/wasm-stages.log"
run_wasm_stages >"$wasm_log" 2>&1 &
wasm_stages=$!
run_timed formatter-integration "$root_dir/tests/integration/test-haxeon-formatter.sh"
run_timed native-call-integration "$root_dir/tests/integration/test-native-call.sh"
run_timed hxi-call-integration "$root_dir/tests/integration/test-hxi-call.sh"

# These project tests build below their own mktemp project roots and use
# separate source caches, so they can share runner slots without racing on the
# repository's `out/` tree.
if [[ -z ${HAXEON_HAXE:-} ]]; then
	test_cli_hl="$root_dir/out/test-tools/haxeon-cli.hl"
	mkdir -p "$(dirname "$test_cli_hl")"
	run_timed test-cli-build "$haxe" --cwd "$root_dir" -cp src -hl "$test_cli_hl" -main tools.HaxeonCli
fi
run_isolated_integration_group \
	tests/integration/test-cxx-project-ffi.sh \
	tests/integration/test-cxx-project-ffi-thunks.sh \
	tests/integration/test-cxx-project-ffi-cmake.sh \
	tests/integration/test-cmake-native-package.sh \
	tests/integration/test-git-package-lock.sh \
	tests/integration/test-workspace.sh

# The C++ FFI fixtures write distinct out/ files; with the native runtime already built
# (HAXEON_NATIVE_READY) they share no build tree, so they share runner slots too.
run_isolated_integration_group \
	tests/integration/test-cxx-hxi-call.sh \
	tests/integration/test-cxx-owned.sh \
	tests/integration/test-cxx-lifetime.sh \
	tests/integration/test-cxx-virtual.sh \
	tests/integration/test-cxx-thunks.sh \
	tests/integration/test-cxx-string-view.sh \
	tests/integration/test-cxx-span.sh \
	tests/integration/test-cxx-msvc-profile.sh
run_timed profiler-disconnect-integration "$root_dir/tests/integration/test-profiler-disconnect.sh"
run_timed process-output-capture-integration bash "$root_dir/tests/integration/test-process-output-capture.sh"

wasm_status=0
wait "$wasm_stages" || wasm_status=$?
cat "$wasm_log"
exit "$wasm_status"
