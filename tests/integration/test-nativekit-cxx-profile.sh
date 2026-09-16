#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)

if [[ -z "${NATIVEKIT_ROOT:-}" ]]; then
	echo "SKIP NativeKit C++ profile audit (set NATIVEKIT_ROOT to enable)"
	exit 0
fi

nativekit_root=$(cd "$NATIVEKIT_ROOT" && pwd)
build_dir=${NATIVEKIT_BUILD_DIR:-}
if [[ -z "$build_dir" ]]; then
	if [[ -d "$nativekit_root/build-ui-integrated" ]]; then
		build_dir="$nativekit_root/build-ui-integrated"
	else
		build_dir="$nativekit_root/build"
	fi
fi
build_dir=$(cd "$build_dir" && pwd)

header="$nativekit_root/modules/ui/src/display_list/display_list.h"
compile_commands="$build_dir/compile_commands.json"
library=${NATIVEKIT_UI_LIBRARY:-}
if [[ -z "$library" ]]; then
	for candidate in \
		"$build_dir/modules/ui/libnativekit_ui.so" \
		"$build_dir/modules/ui/libnativekit_ui.dylib" \
		"$build_dir/modules/ui/nativekit_ui.dll"; do
		if [[ -f "$candidate" ]]; then
			library="$candidate"
			break
		fi
	done
fi

for required in "$header" "$compile_commands" "$library"; do
	if [[ ! -e "$required" ]]; then
		echo "NativeKit C++ profile audit requires: $required" >&2
		exit 1
	fi
done

case "$(uname -s):$(uname -m)" in
	Linux:x86_64)
		target="x86_64-linux-gnu"
		;;
	Linux:aarch64|Linux:arm64)
		target="aarch64-linux-gnu"
		;;
	Darwin:x86_64)
		target="x86_64-apple-darwin"
		;;
	Darwin:arm64)
		target="arm64-apple-darwin"
		;;
	*)
		echo "unsupported host for NativeKit C++ profile audit" >&2
		exit 1
		;;
esac

run_dir=$(mktemp -d "$repo_dir/out/nativekit-cxx-profile.XXXXXX")
trap 'rm -rf -- "$run_dir"' EXIT

set +e
"$repo_dir/scripts/haxeon-ffi-import" \
	--language=c++ \
	--std=c++20 \
	--target="$target" \
	--include="$nativekit_root/modules/ui/src" \
	--compile-commands="$compile_commands" \
	--library="$library" \
	--interface=NativeKitUiInternalCxx \
	--output="$run_dir/nativekit-ui-internal.hxi" \
	"$header" \
	>"$run_dir/stdout" 2>"$run_dir/stderr"
status=$?
set -e

if [[ $status -eq 0 ]]; then
	echo "NativeKit DisplayList unexpectedly passed CXX_ABI_V1" >&2
	exit 1
fi

diagnostics="$run_dir/stderr"
grep -q "CXX008.*nkui::DisplayList::DisplayList" "$diagnostics"
grep -q "CXX003.*nkui::DisplayList::reset" "$diagnostics"
if grep -q "std::launder\|__get_first_arg" "$diagnostics"; then
	echo "C++ system-header declarations leaked into the NativeKit diagnostics" >&2
	exit 1
fi

echo "PASS NativeKit C++ profile audit: internal DisplayList is rejected with actionable CXX diagnostics"
