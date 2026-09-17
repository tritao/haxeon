#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)

source_paths=(
	"$root_dir/src/runtime"
	"$root_dir/stdlib/runtime/hashlink"
	"$root_dir/native/runtime"
	"$root_dir/vendor/hashlink/src/hlmodule.h"
	"$root_dir/vendor/hashlink/src/hlruntime.c"
)

required_symbols=(
	"hl_runtime_module_load_haxe_metadata"
	"hl_runtime_module_apply_haxe_patch"
	"native_runtime_module_load_haxe_metadata"
	"native_runtime_module_apply_haxe_patch"
)

canonical_backend="$root_dir/stdlib/runtime/hashlink/HlRuntimeJitBackend.hx"
legacy_backend="$root_dir/stdlib/runtime/hashlink/HlLegacyRuntimePatchBackend.hx"

if rg -n -- 'function (patch|patchCode|patchCodeWithHaxeTypes)\(' "$canonical_backend"; then
	echo "FAIL: Haxe-owned JIT backend still exposes an encoded patch operation" >&2
	exit 1
fi

for symbol in patch patchCode patchCodeWithHaxeTypes; do
	if ! rg -F -q -- "function $symbol(" "$legacy_backend"; then
		echo "FAIL: legacy patch backend is missing $symbol" >&2
		exit 1
	fi
done

for symbol in "${required_symbols[@]}"; do
	if ! rg -F -q -- "$symbol" "${source_paths[@]}"; then
		echo "FAIL: Haxe-owned runtime boundary is missing $symbol" >&2
		exit 1
	fi
done

removed_symbols=(
	"loadCodeManifest"
	"native_runtime_module_load_code"
	"native_runtime_module_load_code_manifest"
	"native_runtime_module_patch_code_haxe_metadata"
	"hl_runtime_module_load_code_manifest"
	"hl_runtime_module_apply_hlp_capture_metadata_input"
)

for symbol in "${removed_symbols[@]}"; do
	if rg -F -n -- "$symbol" "${source_paths[@]}"; then
		echo "FAIL: removed Haxe-owned runtime symbol returned: $symbol" >&2
		exit 1
	fi
done

printf 'PASS: Haxe-owned runtime boundary exposes only canonical load/patch symbols\n'
