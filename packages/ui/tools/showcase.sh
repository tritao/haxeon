#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

cmake -S "$module_dir" -B "$build_dir" -DNKUI_NATIVEKIT_DIR="$repo_dir" -DNK_BUILD_EXAMPLES=ON
cmake --build "$build_dir" --target nativekit_ui
"$module_dir/tools/check-hxi.sh"
if [[ -x "$haxeon_dir/scripts/build-runtime.sh" ]]; then
    (cd "$haxeon_dir" && scripts/build-runtime.sh)
elif [[ -x "$haxeon_dir/scripts/build-native.sh" ]]; then
    (cd "$haxeon_dir" && scripts/build-native.sh)
fi

(cd "$haxeon_dir" && .tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler \
    --output="$artifact" \
    --entry=ShowcaseDesktop \
    --root="$module_dir/examples/ui_showcase" \
    --root="$module_dir/haxe" \
    --root="$editor_dir/src" \
    --root="$module_dir/bindings/haxe" \
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
    "$module_dir/haxe/haxeon/ui/core/"*.hx \
    "$editor_dir/src/haxeon/editor/"*.hx \
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
    "$module_dir/haxe/haxeon/ui/theme/"*.hx \
    "$module_dir/haxe/haxeon/ui/semantics/"*.hx \
    "$module_dir/haxe/haxeon/ui/debug/"*.hx \
    "$module_dir/haxe/haxeon/ui/gestures/"*.hx \
    "$module_dir/haxe/haxeon/ui/animation/"*.hx \
    "$haxeon_dir/packages/platform/src/haxeon/platform/GraphicsImageRef.hx" \
    "$module_dir/bindings/haxe/haxeon/ui/"*.hx \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitEvent.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitEvents.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitEventValue.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitHttpEvents.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitHttpResponse.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitEventContext.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitEventBytes.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitWindowEvents.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitInputEvents.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitServiceEvents.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitResourceEvents.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitRequests.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitRequestOutcome.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitWindow.hx" \
    "$haxeon_dir/packages/platform/src/haxeon/platform/NativeKitWebView.hx")

echo "showcase: built $artifact"
if [[ "$build_only" == true ]]; then
    exit 0
fi

font_path=${NKUI_TEST_FONT_PATH:-"$module_dir/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf"}
emoji_path=${NKUI_COLOR_FONT_PATH:-"$module_dir/vendor/skribidi/example/data/NotoColorEmoji-Regular.ttf"}
runtime_library_path="$build_dir:$build_dir/nativekit/modules/gpu:$build_dir/nativekit:$haxeon_dir/out:$haxeon_dir/vendor/hashlink"
hashlink_runtime="$haxeon_dir/vendor/hashlink/hl"
if [[ -x "$haxeon_dir/.tools/hashlink/hl" ]]; then
    hashlink_runtime="$haxeon_dir/.tools/hashlink/hl"
    runtime_library_path="$build_dir:$build_dir/nativekit/modules/gpu:$build_dir/nativekit:$haxeon_dir/out:$haxeon_dir/.tools/hashlink"
fi
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    runtime_library_path="$runtime_library_path:$LD_LIBRARY_PATH"
fi

(cd "$haxeon_dir/out" && \
    NKUI_TEST_FONT_PATH="$font_path" \
    NKUI_COLOR_FONT_PATH="$emoji_path" \
	NKUI_SHOWCASE_IMAGE_PATH="${NKUI_SHOWCASE_IMAGE_PATH:-$repo_dir/vendor/sokol/assets/logo_s_large.png}" \
    LD_LIBRARY_PATH="$runtime_library_path" \
    "$hashlink_runtime" "$artifact" "${program_args[@]}")
