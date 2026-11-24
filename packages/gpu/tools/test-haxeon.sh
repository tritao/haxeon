#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$nativekit_dir/build-gpu"}

cmake -S "$nativekit_dir" -B "$build_dir" -GNinja -DCMAKE_BUILD_TYPE=Debug \
    -DNK_BUILD_GPU=ON -DNK_BUILD_TESTS=ON -DNK_BUILD_EXAMPLES=ON
cmake --build "$build_dir"
HAXEON_DIR="$haxeon_dir" "$package_dir/tools/update-haxeon-hxi.sh" --check
(cd "$haxeon_dir" && ./scripts/build-native.sh)

project="$package_dir/tests"
HAXEON_NATIVE_READY=1 "$haxeon_dir/scripts/haxeon" build --compiler-only --project "$project/haxeon.json"
output="$project/../../../out/packages/gpu/tests/host"
generated="$output/generated/shaders/Fixture.hx"
grep -qF '@:assertLayout(48, "shift", 0, "weights", 16, "weights_1", 32)' "$generated"
grep -qF 'public var weights_1_c3:Float32;' "$generated"
grep -qF 'textures: [{view: 0, sampler: 0, stage: ShaderStage.Fragment, type: ImageType.TwoD, name: "tex_smp"}]' "$generated"
grep -qF 'layout: new VertexLayout(16, [{slot: 0, bufferIndex: 0, offset: 0, format: VertexFormat.Float2}, {slot: 1, bufferIndex: 0, offset: 8, format: VertexFormat.Float2}])' "$generated"

hashlink_dir=$("$haxeon_dir/scripts/hashlink-path.sh")
set +e
(cd "$haxeon_dir/out" && \
	LD_LIBRARY_PATH="$build_dir/modules/gpu:$build_dir:$haxeon_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	xvfb-run -a "$hashlink_dir/hl" "$output/main.hl")
status=$?
set -e
if [[ $status -ne 42 ]]; then
	echo "test-haxeon: stress scene returned $status, expected 42" >&2
	exit 1
fi
echo "PASS: Haxeon rendered 400 textured quads through immediate and batched paths"
