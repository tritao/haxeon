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
		shared_flag="-shared"
		;;
	Linux:aarch64|Linux:arm64)
		target="aarch64-linux-gnu"
		shared_flag="-shared"
		;;
	Darwin:x86_64)
		target="x86_64-apple-darwin"
		shared_flag="-dynamiclib"
		;;
	Darwin:arm64)
		target="arm64-apple-darwin"
		shared_flag="-dynamiclib"
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

positive_dir="$run_dir/positive"
mkdir -p "$positive_dir/projection"
positive_hxi="$positive_dir/nativekit-display-list.hxi"
positive_thunks="$positive_dir/nativekit-display-list-generated.cpp"
positive_library="$positive_dir/libnativekit_display_list_fixture.so"

"$repo_dir/scripts/haxeon-ffi-import" \
	--language=c++ \
	--std=c++20 \
	--target="$target" \
	--include="$nativekit_root/modules/ui/src" \
	--library="$positive_library" \
	--interface=NativeKitDisplayList \
	--cxx-thunks="$positive_thunks" \
	--haxe-output-dir="$positive_dir/projection" \
	--output="$positive_hxi" \
	--cxx-select=nkui::DisplayList::reset \
	--cxx-select=nkui::DisplayList::size \
	--cxx-select=nkui::haxeon_display_list_acquire \
	"$repo_dir/tests/ffi/nativekit_display_list_bridge.hpp"

cxx="${CXX:-c++}"
case "$(uname -s)" in
	Linux)
		positive_library="$positive_dir/libnativekit_display_list_fixture.so"
		"$cxx" -std=c++20 -fPIC "$shared_flag" \
			"$nativekit_root/modules/ui/src/display_list/display_list.cpp" \
			"$repo_dir/tests/ffi/nativekit_display_list_bridge.cpp" \
			"$positive_thunks" \
			-I"$nativekit_root/modules/ui/src" \
			-o "$positive_library"
		;;
	Darwin)
		positive_library="$positive_dir/libnativekit_display_list_fixture.dylib"
		"$cxx" -std=c++20 -fPIC "$shared_flag" \
			"$nativekit_root/modules/ui/src/display_list/display_list.cpp" \
			"$repo_dir/tests/ffi/nativekit_display_list_bridge.cpp" \
			"$positive_thunks" \
			-I"$nativekit_root/modules/ui/src" \
			-o "$positive_library"
		;;
esac
sed -i "s#${positive_dir}/libnativekit_display_list_fixture.so#${positive_library}#" "$positive_hxi"
grep -q 'public function reset():Void' "$positive_dir/projection/DisplayList.hx"
grep -q 'public function size():haxe.Int64' "$positive_dir/projection/DisplayList.hx"
grep -q 'DisplayListFunctions' "$positive_dir/projection/NativeKitDisplayListFunctions.hx"

"$repo_dir/.tools/haxe/haxe" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run NativeKitCxxMain \
	"$repo_dir/out/nativekit-cxx-display-list-test.hl" "$positive_hxi" "$positive_dir/projection/DisplayList.hx" \
	"$positive_dir/projection/NativeKitDisplayListFunctions.hx"
(
	cd "$repo_dir/out"
	set +e
	LD_LIBRARY_PATH="$positive_dir:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/.tools/hashlink/hl" nativekit-cxx-display-list-test.hl
	status=$?
	set -e
	if [[ $status -ne 42 ]]; then
		echo "NativeKit DisplayList C++ call returned $status, expected 42" >&2
		exit 1
	fi
)
echo "PASS NativeKit C++ source integration: DisplayList methods execute through generated Haxeon thunks"
