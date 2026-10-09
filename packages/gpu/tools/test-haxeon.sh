#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"
build_dir=${NATIVEKIT_BUILD_DIR:-"$nativekit_dir/build-gpu"}

cmake -S "$nativekit_dir" -B "$build_dir" -GNinja -DCMAKE_BUILD_TYPE=Debug \
    -DNK_BUILD_GPU=ON -DNK_BUILD_TESTS=ON -DNK_BUILD_EXAMPLES=ON
cmake --build "$build_dir"
"$gpu_dir/tools/check-hxi.sh"
if [[ -x "$haxeon_dir/scripts/build-runtime.sh" ]]; then
	"$haxeon_dir/scripts/build-runtime.sh"
elif [[ -x "$haxeon_dir/scripts/build-native.sh" ]]; then
	(cd "$haxeon_dir" && ./scripts/build-native.sh)
else
	echo "test-haxeon: Haxeon runtime build script not found" >&2
	exit 2
fi

hashlink_runtime="$haxeon_dir/.tools/hashlink/hl"
if [[ ! -x "$hashlink_runtime" ]]; then
	hashlink_runtime="$haxeon_dir/vendor/hashlink/hl"
fi
if [[ ! -x "$hashlink_runtime" ]]; then
	echo "test-haxeon: missing HashLink runtime in .tools/hashlink or vendor/hashlink" >&2
	exit 2
fi

(cd "$haxeon_dir" && .tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler \
    --output="$build_dir/haxeon-triangle.hl" \
    --entry=Triangle \
    --root="$gpu_dir/tests" \
    --root="$gpu_dir/src" \
    --root="$platform_dir/src" \
    --ffi-interface="$platform_dir/bindings/nativekit.hxi" \
    --ffi-projection="$platform_dir/bindings/nativekit.hxmap" \
    --ffi-interface="$platform_dir/bindings/nativekit-net.hxi" \
    --ffi-projection="$platform_dir/bindings/nativekit-net.hxmap" \
    --ffi-interface="$gpu_dir/bindings/nativekit-gpu.hxi" \
    --ffi-projection="$gpu_dir/bindings/nativekit-gpu.hxmap" \
    "$gpu_dir/tests/Triangle.hx" \
    "$gpu_dir/src/haxeon/gpu/Buffer.hx" \
    "$gpu_dir/src/haxeon/gpu/BufferDesc.hx" \
    "$gpu_dir/src/haxeon/gpu/AttachmentAction.hx" \
    "$gpu_dir/src/haxeon/gpu/Batch.hx" \
    "$gpu_dir/src/haxeon/gpu/CommandBuffer.hx" \
    "$gpu_dir/src/haxeon/gpu/Enums.hx" \
    "$gpu_dir/src/haxeon/gpu/Features.hx" \
    "$gpu_dir/src/haxeon/gpu/Image.hx" \
    "$gpu_dir/src/haxeon/gpu/ImageFormatSupport.hx" \
    "$gpu_dir/src/haxeon/gpu/Limits.hx" \
    "$gpu_dir/src/haxeon/gpu/Pipeline.hx" \
    "$gpu_dir/src/haxeon/gpu/Readback.hx" \
    "$gpu_dir/src/haxeon/gpu/Renderer.hx" \
    "$gpu_dir/src/haxeon/gpu/Sampler.hx" \
    "$gpu_dir/src/haxeon/gpu/Shader.hx" \
    "$gpu_dir/src/haxeon/gpu/Surface.hx" \
    "$gpu_dir/src/haxeon/gpu/SurfaceFrame.hx" \
    "$gpu_dir/src/haxeon/gpu/Timestamp.hx" \
    "$gpu_dir/src/haxeon/gpu/Uniforms.hx" \
    "$gpu_dir/src/haxeon/gpu/GpuResult.hx" \
    "$gpu_dir/src/haxeon/gpu/ImageDesc.hx" \
    "$gpu_dir/src/haxeon/gpu/RenderPassDesc.hx" \
    "$platform_dir/src/haxeon/platform/GraphicsImageRef.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitEvent.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitHttpEvents.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitHttpResponse.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitEvents.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitEventValue.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitEventContext.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitEventBytes.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitWindowEvents.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitInputEvents.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitServiceEvents.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitResourceEvents.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitRequests.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitRequestOutcome.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitWindow.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitWebView.hx" \
    "$platform_dir/src/haxeon/platform/NativeKitRuntime.hx")

set +e
(cd "$haxeon_dir/out" && \
	LD_LIBRARY_PATH="$build_dir/modules/gpu:$build_dir:$haxeon_dir/out:$haxeon_dir/.tools/hashlink:$haxeon_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	xvfb-run -a "$hashlink_runtime" "$build_dir/haxeon-triangle.hl")
status=$?
set -e
if [[ $status -ne 42 ]]; then
	echo "test-haxeon: stress scene returned $status, expected 42" >&2
	exit 1
fi
echo "PASS: Haxeon rendered 400 textured quads through immediate and batched paths"
