#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
nativekit_root=${NATIVEKIT_ROOT:?Set NATIVEKIT_ROOT to the NativeKit scene worktree}
nativekit_build=${NATIVEKIT_BUILD:?Set NATIVEKIT_BUILD to a shared NativeKit build directory}
target=${NATIVEKIT_HAXE_TARGET:-x86_64-linux-gnu}
haxe_bin=${HAXEON_HAXE_BIN:-"$repo_dir/.tools/haxe/haxe"}
hashlink_bin=${HAXEON_HASHLINK_BIN:-"$repo_dir/.tools/hashlink/hl"}
haxeon_runtime_dir=${HAXEON_RUNTIME_DIR:-"$repo_dir/out"}
generated_dir="$repo_dir/out/nativekit-scene-hxi"
mkdir -p "$generated_dir"

scene_header="$nativekit_root/modules/scene/include/nativekit_scene.h"
render_header="$nativekit_root/modules/scene_render/include/nativekit_scene_render.h"
nativekit_import_header="$nativekit_root/bindings/haxe/nativekit_import.h"
gpu_import_header="$nativekit_root/modules/gpu/bindings/nativekit_gpu_import.h"
nativekit_header="$nativekit_root/include/nativekit.h"
graphics_header="$nativekit_root/include/nativekit_graphics.h"
gpu_header="$nativekit_root/modules/gpu/include/nativekit_gpu.h"

HAXEON_HAXE_BIN="$haxe_bin" "$repo_dir/scripts/haxeon-ffi-import" \
	--target="$target" \
	--library=nativekit \
	--interface=NativeKit \
	--include="$nativekit_root/include" \
	--output="$generated_dir/nativekit.hxi" \
	--source-label=bindings/haxe/nativekit_import.h \
	"$nativekit_import_header"

HAXEON_HAXE_BIN="$haxe_bin" "$repo_dir/scripts/haxeon-ffi-import" \
	--target="$target" \
	--library=nativekit_gpu \
	--interface=NativeKitGpu \
	--depends=NativeKit \
	--include="$nativekit_root/modules/gpu/include" \
	--include="$nativekit_root/modules/gpu/bindings" \
	--include="$nativekit_root/include" \
	--exclude-header="$nativekit_header" \
	--exclude-header="$graphics_header" \
	--output="$generated_dir/nativekit-gpu.hxi" \
	--source-label=modules/gpu/bindings/nativekit_gpu_import.h \
	"$gpu_import_header"

HAXEON_HAXE_BIN="$haxe_bin" "$repo_dir/scripts/haxeon-ffi-import" \
	--target="$target" \
	--library=nativekit_scene \
	--interface=NativeKitScene \
	--include="$nativekit_root/modules/scene/include" \
	--include="$nativekit_root/include" \
	--exclude-header="$nativekit_header" \
	--output="$generated_dir/nativekit-scene.hxi" \
	--source-label=modules/scene/include/nativekit_scene.h \
	"$scene_header"

HAXEON_HAXE_BIN="$haxe_bin" "$repo_dir/scripts/haxeon-ffi-import" \
	--target="$target" \
	--library=nativekit_scene_render \
	--interface=NativeKitSceneRender \
	--depends=NativeKitScene \
	--depends=NativeKitGpu \
	--include="$nativekit_root/modules/scene_render/include" \
	--include="$nativekit_root/modules/scene/include" \
	--include="$nativekit_root/modules/gpu/include" \
	--include="$nativekit_root/include" \
	--exclude-header="$scene_header" \
	--exclude-header="$gpu_header" \
	--exclude-header="$graphics_header" \
	--exclude-header="$nativekit_header" \
	--output="$generated_dir/nativekit-scene-render.hxi" \
	--source-label=modules/scene_render/include/nativekit_scene_render.h \
	"$render_header"

output="$generated_dir/nativekit-scene.hx.hl"
"$haxe_bin" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run HxiNativeKitSceneMain \
	"$output" "$generated_dir/nativekit-scene.hxi" "$generated_dir/nativekit-scene-render.hxi" \
	"$nativekit_root" "$generated_dir/nativekit.hxi" "$generated_dir/nativekit-gpu.hxi"

set +e
LD_LIBRARY_PATH="$haxeon_runtime_dir:$repo_dir/.tools/hashlink:$nativekit_build/modules/scene_render:$nativekit_build/modules/scene:$nativekit_build/modules/gpu:$nativekit_build:${LD_LIBRARY_PATH:-}" \
	xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 "$hashlink_bin" "$output"
status=$?
set -e
if [[ $status -ne 42 ]]; then
	echo "Haxeon NativeKit scene smoke test returned $status, expected 42" >&2
	exit 1
fi
