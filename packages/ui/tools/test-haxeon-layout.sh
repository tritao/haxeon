#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}
materia_dir=${MATERIA_DIR:-"$(dirname "$haxeon_dir")"}
repo_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
editor_dir=${HAXEON_EDITOR_DIR:-"$haxeon_dir/packages/editor"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$haxeon_dir/out/packages/ui/native"}

cmake --build "$build_dir" --target nativekit_ui
"$module_dir/tools/check-hxi.sh"
if [[ -x "$haxeon_dir/scripts/build-runtime.sh" ]]; then
	"$haxeon_dir/scripts/build-runtime.sh"
elif [[ -x "$haxeon_dir/scripts/build-native.sh" ]]; then
	(cd "$haxeon_dir" && ./scripts/build-native.sh)
else
	echo "test-haxeon-layout: Haxeon runtime build script not found" >&2
	exit 2
fi

(cd "$haxeon_dir" && .tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler \
	--output="$build_dir/haxeon-ui-layout-session.hl" \
	--entry=LayoutSessionSmoke \
	--root="$module_dir/tests/haxeon" \
	--root="$module_dir/haxe" \
	--root="$module_dir/bindings/haxe" \
	--root="$haxeon_dir/packages/platform/src" \
	--ffi-interface="$haxeon_dir/packages/platform/bindings/nativekit.hxi" \
	--ffi-projection="$haxeon_dir/packages/platform/bindings/nativekit.hxmap" \
	--ffi-interface="$haxeon_dir/packages/platform/bindings/nativekit-net.hxi" \
	--ffi-projection="$haxeon_dir/packages/platform/bindings/nativekit-net.hxmap" \
	--ffi-interface="$module_dir/bindings/nativekit-ui.hxi" \
	--ffi-projection="$module_dir/bindings/nativekit-ui.hxmap" \
	"$module_dir/tests/haxeon/LayoutSessionSmoke.hx" \
	"$module_dir/haxe/haxeon/ui/style/"*.hx \
	"$haxeon_dir/packages/platform/src/haxeon/platform/GraphicsImageRef.hx" \
	"$module_dir/bindings/haxe/haxeon/ui/"*.hx)

(cd "$haxeon_dir/out" && \
	NKUI_TEST_FONT_PATH="$module_dir/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf" \
	LD_LIBRARY_PATH="$build_dir:$build_dir/nativekit/modules/gpu:$build_dir/nativekit${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$haxeon_dir/vendor/hashlink/hl" "$build_dir/haxeon-ui-layout-session.hl")
