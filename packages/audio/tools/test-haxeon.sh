#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$haxeon_dir/out/packages/audio/native"}
cmake -S "$nativekit_dir" -B "$build_dir" -GNinja -DCMAKE_BUILD_TYPE=Debug \
    -DNK_BUILD_AUDIO=ON -DNK_BUILD_TESTS=ON -DNK_BUILD_EXAMPLES=OFF
cmake --build "$build_dir"
ctest --test-dir "$build_dir" --output-on-failure -R '^(audio|audio_dsp|audio_effects|audio_routing|audio_sends|miniaudio_splitter|resource_cache)$'
"$package_dir/tools/check-hxi.sh"
if [[ ! -f "$haxeon_dir/out/haxeon_runtime.hdll" ]]; then
    (cd "$haxeon_dir" && ./scripts/build-native.sh)
fi
mapfile -t sources < <(find "$package_dir/src" "$haxeon_dir/packages/platform/src" -name '*.hx' -print | sort)
for fixture in AudioSmoke; do
    (cd "$haxeon_dir" && .tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler \
        --output="$build_dir/$fixture.hl" --entry="$fixture" \
        --root="$haxeon_dir/packages/platform/tests" --root="$package_dir/tests" --root="$package_dir/src" --root="$haxeon_dir/packages/platform/src" \
        --ffi-interface="$haxeon_dir/packages/platform/bindings/nativekit.hxi" \
        --ffi-projection="$haxeon_dir/packages/platform/bindings/nativekit.hxmap" \
        --ffi-interface="$haxeon_dir/packages/platform/bindings/nativekit-net.hxi" \
        --ffi-projection="$haxeon_dir/packages/platform/bindings/nativekit-net.hxmap" \
        --ffi-interface="$package_dir/bindings/nativekit-audio.hxi" \
        --ffi-projection="$package_dir/bindings/nativekit-audio.hxmap" \
        "$package_dir/tests/$fixture.hx" "$haxeon_dir/packages/platform/tests/NativeKitEventDecoderTests.hx" "${sources[@]}")
    status=0
    LD_LIBRARY_PATH="$build_dir:$haxeon_dir/out:$haxeon_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$haxeon_dir/.tools/hashlink/hl" "$build_dir/$fixture.hl" || status=$?
    if [[ $status == 77 ]]; then echo "SKIP: $fixture has no audio device";
    elif [[ $status != 0 ]]; then exit "$status"; fi
done
echo "PASS: managed audio and DSP smoke"
