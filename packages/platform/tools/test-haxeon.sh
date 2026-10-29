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
native_build_dir=${NATIVEKIT_BUILD_DIR:-"$test_root/build"}
http_fixture_pid=""
cleanup() {
    if [[ -n "$http_fixture_pid" ]]; then
        kill "$http_fixture_pid" 2>/dev/null || true
        wait "$http_fixture_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_root"
}
trap cleanup EXIT

http_fixture_port=0
if command -v node >/dev/null 2>&1; then
    node "$platform_dir/tests/http-fixture.mjs" >"$test_root/http-port" 2>"$test_root/http-fixture.log" &
    http_fixture_pid=$!
    for _ in {1..50}; do
        [[ -s "$test_root/http-port" ]] && break
        sleep 0.1
    done
    if [[ ! -s "$test_root/http-port" ]]; then
        cat "$test_root/http-fixture.log" >&2
        echo "test-haxeon: local HTTP fixture did not start" >&2
        exit 1
    fi
    http_fixture_port=$(<"$test_root/http-port")
    if [[ ! "$http_fixture_port" =~ ^[0-9]+$ ]] || ((http_fixture_port < 1 || http_fixture_port > 65535)); then
        echo "test-haxeon: local HTTP fixture returned an invalid port" >&2
        exit 1
    fi
else
    echo "test-haxeon: Node.js unavailable; skipping the optional loopback HTTP runtime test" >&2
fi

HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-hxi.sh" --check
HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-net-hxi.sh" --check
HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-vulkan-hxi.sh" --check

cmake -S "$nativekit_dir" -B "$native_build_dir" -GNinja \
    -DCMAKE_BUILD_TYPE=Debug -DNK_BUILD_SHARED=ON \
    -DNK_USE_SYSTEM_CURL=ON \
    -DNK_BUILD_EXAMPLES=OFF -DNK_BUILD_TESTS=OFF
cmake --build "$native_build_dir"
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
        --ffi-interface="$platform_dir/bindings/nativekit-net.hxi" \
        --ffi-projection="$platform_dir/bindings/nativekit-net.hxmap" \
        --ffi-interface="$platform_dir/bindings/nativekit-vulkan.hxi" \
        --ffi-projection="$platform_dir/bindings/nativekit-vulkan.hxmap" \
        "$platform_dir/tests/Smoke.hx" \
        "$platform_dir/tests/NativeKitHttpEventTests.hx" \
        "$platform_dir/tests/NativeKitFileWatchTests.hx" \
        "$platform_dir/src/haxeon/platform/FileWatch.hx" \
        "$platform_dir/src/haxeon/platform/internal/event/NativeEvent.hx" \
        "$platform_dir/src/haxeon/platform/event/PlatformEvent.hx" \
        "$platform_dir/src/haxeon/platform/internal/event/HttpEventDecoder.hx" \
        "$platform_dir/src/haxeon/platform/http/HttpResponse.hx" \
        "$platform_dir/src/haxeon/platform/internal/event/EventSnapshot.hx" \
		"$platform_dir/src/haxeon/platform/internal/event/EventBytes.hx" \
		"$platform_dir/tests/NativeKitEventDecoderTests.hx" \
        "$platform_dir/src/haxeon/platform/internal/event/WindowEventDecoder.hx" \
        "$platform_dir/src/haxeon/platform/internal/event/InputEventDecoder.hx" \
		"$platform_dir/src/haxeon/platform/input/TextInput.hx" \
        "$platform_dir/src/haxeon/platform/Runtime.hx" \
        "$platform_dir/src/haxeon/platform/Window.hx" \
        "$platform_dir/src/haxeon/platform/Surface.hx" \
        "$platform_dir/src/haxeon/platform/WebView.hx" \
        "$platform_dir/src/haxeon/platform/NativeKitError.hx" \
        "$platform_dir/src/haxeon/platform/interop/VulkanExtensions.hx" \
        "$platform_dir/src/haxeon/platform/internal/event/ServiceEventDecoder.hx" \
        "$platform_dir/src/haxeon/platform/internal/event/ResourceEventDecoder.hx" \
        "$platform_dir/src/haxeon/platform/async/Outcome.hx" \
        "$platform_dir/src/haxeon/platform/async/Future.hx" \
        "$platform_dir/src/haxeon/platform/async/Promise.hx" \
        "$platform_dir/src/haxeon/platform/async/Task.hx" \
        "$platform_dir/src/haxeon/platform/async/Requests.hx" \
        "$platform_dir/src/haxeon/platform/event/EventPump.hx"
)

set +e
runtime_library_path="$native_build_dir:$haxeon_dir/out:$haxeon_dir/.tools/hashlink:$haxeon_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if command -v xvfb-run >/dev/null; then
    xvfb-run -a env NATIVEKIT_HTTP_FIXTURE_PORT="$http_fixture_port" LD_LIBRARY_PATH="$runtime_library_path" \
        "$hashlink_runtime" "$test_root/nativekit-smoke.hl"
else
    NATIVEKIT_HTTP_FIXTURE_PORT="$http_fixture_port" LD_LIBRARY_PATH="$runtime_library_path" \
        "$hashlink_runtime" "$test_root/nativekit-smoke.hl"
fi
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "test-haxeon: smoke test returned $status, expected 42" >&2
    exit 1
fi

if ((http_fixture_port > 0)); then
    echo "PASS: platform smoke exercised NativeKit lifecycle, typed HTTP request/response snapshots, request outcomes, UTF-8, handles, and output buffers"
else
    echo "PASS: platform smoke exercised NativeKit lifecycle, request outcomes, UTF-8, handles, and output buffers (loopback HTTP test skipped)"
fi
