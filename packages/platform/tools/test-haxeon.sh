#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"

if [[ ! -x "$haxeon_dir/.tools/haxe/haxe" ]]; then
    echo "test-haxeon: missing Haxeon compiler: $haxeon_dir/.tools/haxe/haxe" >&2
    exit 2
fi

test_root=$(mktemp -d)
cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT

HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-hxi.sh" --check
HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-vulkan-hxi.sh" --check

cmake -S "$nativekit_dir" -B "$test_root/build" -GNinja \
    -DCMAKE_BUILD_TYPE=Debug -DNK_BUILD_SHARED=ON \
    -DNK_BUILD_EXAMPLES=OFF -DNK_BUILD_TESTS=OFF
cmake --build "$test_root/build"
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

(
    cd "$haxeon_dir"
    .tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler \
        --output="$test_root/nativekit-smoke.hl" \
        --entry=Smoke \
        --root="$platform_dir/tests" \
        --root="$platform_dir/src" \
        --ffi-interface="$platform_dir/bindings/nativekit.hxi" \
        --ffi-projection="$platform_dir/bindings/nativekit.hxmap" \
        --ffi-interface="$platform_dir/bindings/nativekit-vulkan.hxi" \
        --ffi-projection="$platform_dir/bindings/nativekit-vulkan.hxmap" \
        "$platform_dir/tests/Smoke.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitEvent.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitEventValue.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitEventContext.hx" \
		"$platform_dir/src/haxeon/platform/NativeKitEventBytes.hx" \
		"$platform_dir/tests/NativeKitEventDecoderTests.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitWindowEvents.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitInputEvents.hx" \
		"$platform_dir/src/haxeon/platform/NativeKitTextInput.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitRuntime.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitWindow.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitSurface.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitWebView.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitError.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitVulkanExtensions.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitServiceEvents.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitResourceEvents.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitRequestOutcome.hx" \
        "$platform_dir/src/haxeon/platform/NativeFuture.hx" \
        "$platform_dir/src/haxeon/platform/NativePromise.hx" \
        "$platform_dir/src/haxeon/platform/NativeTask.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitRequests.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitEvents.hx"
)

set +e
runtime_library_path="$test_root/build:$haxeon_dir/out:$haxeon_dir/.tools/hashlink:$haxeon_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if command -v xvfb-run >/dev/null; then
    xvfb-run -a env LD_LIBRARY_PATH="$runtime_library_path" \
        "$hashlink_runtime" "$test_root/nativekit-smoke.hl"
else
    LD_LIBRARY_PATH="$runtime_library_path" \
        "$hashlink_runtime" "$test_root/nativekit-smoke.hl"
fi
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "test-haxeon: smoke test returned $status, expected 42" >&2
    exit 1
fi

echo "PASS: generated Haxeon bindings exercised NativeKit lifecycle, request outcomes/cancellation, copied event payloads, UTF-8, handles, and output buffers"
