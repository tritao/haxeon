#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$module_dir/tools/ui-sources.sh" "$module_dir"
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}
materia_dir=${MATERIA_DIR:-"$(dirname "$haxeon_dir")"}
repo_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
editor_dir=${HAXEON_EDITOR_DIR:-"$haxeon_dir/packages/editor"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$haxeon_dir/out/packages/ui/native"}
artifact="$build_dir/nativekit_ui_showcase.hl"
build_only=false
program_args=()

for arg in "$@"; do
    if [[ "$arg" == "--build-only" ]]; then
        build_only=true
    else
        program_args+=("$arg")
    fi
done

if [[ ! -x "$haxeon_dir/.tools/haxe/haxe" ]]; then
    echo "showcase: Haxeon toolchain not found at $haxeon_dir" >&2
    echo "showcase: set HAXEON_DIR to the Haxeon checkout" >&2
    exit 1
fi

cmake -S "$module_dir/native" -B "$build_dir" -DNKUI_NATIVEKIT_DIR="$repo_dir" -DNK_BUILD_EXAMPLES=ON
cmake --build "$build_dir" --target nativekit_ui
HAXEON_DIR="$haxeon_dir" "$module_dir/tools/update-haxeon-hxi.sh" --check
if [[ -x "$haxeon_dir/scripts/build-runtime.sh" ]]; then
    (cd "$haxeon_dir" && scripts/build-runtime.sh)
elif [[ -x "$haxeon_dir/scripts/build-native.sh" ]]; then
    (cd "$haxeon_dir" && scripts/build-native.sh)
fi

(cd "$haxeon_dir" && .tools/haxe/haxe common.hxml --run compiler.tools.HaxeonCompiler \
    --output="$artifact" \
    --entry=ShowcaseDesktop \
    --root="$module_dir/examples/ui_showcase" \
    "${ui_root_flags[@]}" \
    --root="$editor_dir/src" \
    --root="$haxeon_dir/packages/gpu/src" \
    --root="$haxeon_dir/packages/platform/src" \
    --ffi-interface="$haxeon_dir/packages/platform/bindings/nativekit.hxi" \
    --ffi-projection="$haxeon_dir/packages/platform/bindings/nativekit.hxmap" \
    --ffi-interface="$haxeon_dir/packages/platform/bindings/nativekit-net.hxi" \
    --ffi-projection="$haxeon_dir/packages/platform/bindings/nativekit-net.hxmap" \
    --ffi-interface="$module_dir/bindings/nativekit-ui.hxi" \
    --ffi-projection="$module_dir/bindings/nativekit-ui.hxmap" \
    --ffi-interface="$haxeon_dir/packages/gpu/bindings/nativekit-gpu.hxi" \
    --ffi-projection="$haxeon_dir/packages/gpu/bindings/nativekit-gpu.hxmap" \
    --ffi-interface="$module_dir/bindings/nativekit-ui-showcase.hxi" \
    --ffi-projection="$module_dir/bindings/nativekit-ui-showcase.hxmap" \
    "$module_dir/examples/ui_showcase/ShowcaseDesktop.hx" \
    "$module_dir/examples/ui_showcase/ShowcaseWeb.hx" \
    "$module_dir/examples/ui_showcase/Showcase.hx" \
    "$module_dir/examples/ui_showcase/UiExplorer.hx" \
    "$module_dir/examples/ui_showcase/ShowcaseCube.hx" \
    "${ui_modules[@]}" \
    "$editor_dir/src/haxeon/editor/"*.hx \
    "$haxeon_dir/packages/platform/src/haxeon/platform/GraphicsImageRef.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/NativeEvent.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/EventPump.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/PlatformEvent.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/HttpEventDecoder.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/http/HttpResponse.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/EventSnapshot.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/EventBytes.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/WindowEventDecoder.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/InputEventDecoder.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/ServiceEventDecoder.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/event/ResourceEventDecoder.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/async/Requests.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/Window.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/WebView.hx")

echo "showcase: built $artifact"
if [[ "$build_only" == true ]]; then
    exit 0
fi

font_path=${NKUI_TEST_FONT_PATH:-"$module_dir/native/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf"}
emoji_path=${NKUI_COLOR_FONT_PATH:-"$module_dir/native/vendor/skribidi/example/data/NotoColorEmoji-Regular.ttf"}
hashlink_dir=$("$haxeon_dir/scripts/hashlink-path.sh")
hashlink_runtime="$hashlink_dir/hl"
if [[ ! -x "$hashlink_runtime" ]]; then
    echo "Missing checkout-built HashLink: $hashlink_runtime; run scripts/build-native.sh first" >&2
    exit 1
fi
runtime_library_path="$build_dir:$build_dir/nativekit/modules/gpu:$build_dir/nativekit:$haxeon_dir/out:$hashlink_dir"
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    runtime_library_path="$runtime_library_path:$LD_LIBRARY_PATH"
fi

(cd "$haxeon_dir/out" && \
    NKUI_TEST_FONT_PATH="$font_path" \
    NKUI_COLOR_FONT_PATH="$emoji_path" \
	NKUI_SHOWCASE_IMAGE_PATH="${NKUI_SHOWCASE_IMAGE_PATH:-$repo_dir/vendor/sokol/assets/logo_s_large.png}" \
    LD_LIBRARY_PATH="$runtime_library_path" \
    "$hashlink_runtime" "$artifact" "${program_args[@]}")
