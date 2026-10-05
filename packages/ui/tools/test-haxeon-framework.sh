#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}
materia_dir=${MATERIA_DIR:-"$(dirname "$haxeon_dir")"}
repo_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
editor_dir=${HAXEON_EDITOR_DIR:-"$haxeon_dir/packages/editor"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$haxeon_dir/out/packages/ui/native"}
artifact="$build_dir/haxeon-ui-framework.hl"

cmake --build "$build_dir" --target nativekit_ui
"$module_dir/tools/check-hxi.sh"
if [[ -x "$haxeon_dir/scripts/build-runtime.sh" ]]; then
	"$haxeon_dir/scripts/build-runtime.sh"
elif [[ -x "$haxeon_dir/scripts/build-native.sh" ]]; then
	(cd "$haxeon_dir" && ./scripts/build-native.sh)
else
	echo "test-haxeon-framework: Haxeon runtime build script not found" >&2
	exit 2
fi

hashlink_runtime="$haxeon_dir/.tools/hashlink/hl"
if [[ ! -x "$hashlink_runtime" ]]; then
	hashlink_runtime="$haxeon_dir/vendor/hashlink/hl"
fi
if [[ ! -x "$hashlink_runtime" ]]; then
	echo "test-haxeon-framework: missing HashLink runtime in .tools/hashlink or vendor/hashlink" >&2
	exit 2
fi

(cd "$haxeon_dir" && .tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler \
	--output="$artifact" \
	--entry=FrameworkSmoke \
	--root="$module_dir/tests/haxeon" \
	--root="$haxeon_dir/packages/platform/tests" \
	--root="$module_dir/haxe" \
	--root="$editor_dir/src" \
	--root="$module_dir/bindings/haxe" \
	--root="$haxeon_dir/packages/platform/src" \
	--ffi-interface="$haxeon_dir/packages/platform/bindings/nativekit.hxi" \
	--ffi-projection="$haxeon_dir/packages/platform/bindings/nativekit.hxmap" \
	--ffi-interface="$module_dir/bindings/nativekit-ui.hxi" \
	--ffi-projection="$module_dir/bindings/nativekit-ui.hxmap" \
	"$module_dir/tests/haxeon/FrameworkSmoke.hx" \
	"$haxeon_dir/packages/platform/tests/NativeKitEventDecoderTests.hx" \
	"$editor_dir/src/haxeon/editor/"*.hx \
	"$module_dir/haxe/haxeon/ui/core/"*.hx \
	"$module_dir/haxe/haxeon/ui/style/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/"*.hx \
	"$module_dir/haxe/haxeon/ui/docking/"*.hx \
	"$module_dir/haxe/haxeon/ui/editing/"*.hx \
	"$module_dir/haxe/haxeon/ui/plotting/"*.hx \
	"$module_dir/haxe/haxeon/ui/properties/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/collections/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/commands/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/controls/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/docking/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/layout/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/overlays/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/plotting/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/properties/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/scroll/"*.hx \
	"$module_dir/haxe/haxeon/ui/widgets/text/"*.hx \
	"$module_dir/haxe/haxeon/ui/host/"*.hx \
	"$module_dir/bindings/haxe/haxeon/ui/"*.hx)

runtime_library_path="$build_dir:$build_dir/nativekit/modules/gpu:$build_dir/nativekit:$haxeon_dir/out:$haxeon_dir/.tools/hashlink:$haxeon_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if command -v xvfb-run >/dev/null; then
	(cd "$haxeon_dir/out" && \
		NKUI_TEST_FONT_PATH="${NKUI_TEST_FONT_PATH:-$module_dir/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf}" \
		NKUI_TEST_EMOJI_FONT_PATH="${NKUI_TEST_EMOJI_FONT_PATH:-$module_dir/vendor/skribidi/example/data/NotoEmoji-Regular.ttf}" \
		NKUI_TEST_IMAGE_PATH="${NKUI_TEST_IMAGE_PATH:-$repo_dir/vendor/sokol/assets/logo_s_small.png}" \
		xvfb-run -a env LD_LIBRARY_PATH="$runtime_library_path" \
		"$hashlink_runtime" "$artifact")
else
	(cd "$haxeon_dir/out" && \
		NKUI_TEST_FONT_PATH="${NKUI_TEST_FONT_PATH:-$module_dir/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf}" \
		NKUI_TEST_EMOJI_FONT_PATH="${NKUI_TEST_EMOJI_FONT_PATH:-$module_dir/vendor/skribidi/example/data/NotoEmoji-Regular.ttf}" \
		NKUI_TEST_IMAGE_PATH="${NKUI_TEST_IMAGE_PATH:-$repo_dir/vendor/sokol/assets/logo_s_small.png}" \
		LD_LIBRARY_PATH="$runtime_library_path" \
		"$hashlink_runtime" "$artifact")
fi
