#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
project="$work/project with spaces"
mkdir -p "$project/src/shaders" "$project/includes" "$project/library/src/shaders"
mkdir "$work/no-python"
for command in python python3; do
    printf '#!/bin/sh\nprintf "Unexpected Python dependency\\n" >&2\nexit 99\n' > "$work/no-python/$command"
    chmod +x "$work/no-python/$command"
done
haxeon() {
    PATH="$work/no-python:$PATH" "$root/scripts/haxeon" "$@"
}

cd "$project"

ln -s "$root/packages" "$work/packages"
cat > haxeon.json <<'JSON'
{
  "version": 1,
  "package": {"name": "shader-build-test"},
  "entry": "Main",
  "shaderVariants": {"shaders.First": {"default": [], "preview": ["PREVIEW"]}, "shaders.Second": {"default": [], "preview": ["PREVIEW"]}},
  "dependencies": {"haxeon-gpu": {"path": "../packages/gpu"}, "shader-library": {"path": "library"}}
}
JSON

cp "$root/templates/app/shaders/Quad.glsl" src/shaders/Second.glsl
cp src/shaders/Second.glsl library/src/shaders/LibraryQuad.glsl
cat > library/haxeon.json <<'JSON'
{"version":1,"package":{"name":"shader-library"},"scopeSourceRoots":false,"shaderVariants":{"shaders.LibraryQuad":{"default":[],"preview":["PREVIEW"]}}}
JSON
cat > library/src/LibraryScene.hx <<'HX'
import shaders.LibraryQuad;

class LibraryScene {
	public static function stride():Int
		return LibraryQuad.Vertex.stride;

	public static function preview():LibraryQuadVariant
		return LibraryQuadVariant.Preview;
}
HX
{
    printf '%s\n' '@include ../../includes/Colors.glsl'
    sed -e '/^void main() {/i @include_block colors' \
        -e 's/vec4(position, 0.0, 1.0)/vec4(position * scale(), 0.0, 1.0)/' src/shaders/Second.glsl
    printf '%s\n' '@program alternate_quad quad_vs quad_fs'
} > src/shaders/First.glsl
cat > includes/Colors.glsl <<'GLSL'
@block colors
float scale() { return 0.5; }
@end
GLSL
cat > src/Main.hx <<'HX'
import shaders.First;
import shaders.Second;
import LibraryScene;

class Main {
	static function preview():FirstQuadVariant
		return FirstQuadVariant.Preview;

	static function secondPreview():SecondVariant
		return SecondVariant.Preview;

	public static function main():Int
		return First.Vertex.stride == Second.Vertex.stride && LibraryScene.stride() == 16 ? 0 : 1;
}
HX

cat > src/shaders/Step.glsl <<'GLSL'
@cs step_cs
layout(local_size_x=64) in;
struct value { float x; };
layout(binding=0) buffer values { value items[]; };
void main() { items[gl_GlobalInvocationID.x].x *= 2.0; }
@end
@program step step_cs
GLSL

haxeon check --project haxeon.json
output=build/host/generated
first="$output/shaders/First.hx"
second="$output/shaders/Second.hx"
rg -q '^enum FirstQuadVariant \{' "$first"
rg -q '^enum FirstAlternateQuadVariant \{' "$first"
rg -q '^enum SecondVariant \{' "$second"
rg -q 'target: ShaderTarget.Glsl410' "$first"
! rg -q 'target: ShaderTarget.(Glsl300Es|Hlsl5|MetalMacos|MetalIos)' "$first"
# A compute stage needs GLSL 4.3, so only its file compiles for that target.
step="$output/shaders/Step.hx"
rg -q 'target: ShaderTarget.Glsl430' "$step"
rg -q 'vertex: null' "$step"
rg -qF 'storageBuffers: [{view: 0, stage: ShaderStage.Compute, readonly: false, name: "values"}]' "$step"
rg -q 'public static function create' "$step"
rm src/shaders/Step.glsl
rg -qF "$project/includes/Colors.glsl" "$output/shaders.dependencies"
rg -q '^enum LibraryQuadVariant \{' "$output/shaders/LibraryQuad.hx"

sdk_bin=$("$root/scripts/hashlink-path.sh")
mkdir -p "$work/sdk/bin"
cp "$sdk_bin/haxeon" "$work/sdk/bin/"
ln -s "$sdk_bin/haxeon-cli.hl" "$work/sdk/bin/"
ln -s "$sdk_bin/../haxeon-sdk.toml" "$work/sdk/"
status=0
"$work/sdk/bin/haxeon" __generate-shaders "$project" "$work/generated" glsl410 short '{}' \
    '["src/shaders"]' > "$work/missing-driver.log" 2>&1 || status=$?
[[ $status -eq 2 ]]
diff -u <(printf '%s\n' 'haxeon: Missing nkgpu-shaders. Use a host SDK or build nkgpu-shaders for the host.') \
    "$work/missing-driver.log"
cat "$work/missing-driver.log"

signature() {
    stat -c '%y' "$1"
    sha256sum < "$1"
}
original=$(signature "$first")
independent=$(signature "$second")
haxeon check --project haxeon.json
[[ $(signature "$first") == "$original" ]]
[[ $(signature "$second") == "$independent" ]]
sed -i 's/return 0.5/return 0.75/' includes/Colors.glsl
haxeon build --compiler-only --project haxeon.json
[[ $(signature "$first") != "$original" ]]
[[ $(signature "$second") == "$independent" ]]

sed -i 's/return 0.75/return unknown_symbol/' includes/Colors.glsl
if haxeon check --project haxeon.json --diagnostic-format short > "$work/error.log" 2>&1; then
    echo "Expected GLSL type checking to fail" >&2
    exit 1
fi
rg '^includes/Colors.glsl:2:1: E4001:.*unknown_symbol' "$work/error.log"
if haxeon check --project haxeon.json --diagnostic-format full > "$work/error.log" 2>&1; then
    echo "Expected GLSL type checking to fail" >&2
    exit 1
fi
rg -F 'includes/Colors.glsl:2:1: error[E4001]:' "$work/error.log"
sed -i 's/return unknown_symbol/return 0.75/' includes/Colors.glsl
rm src/shaders/Second.glsl
sed -i 's/, "shaders.Second": {"default": \[\], "preview": \["PREVIEW"\]}//' haxeon.json
sed -i '/import shaders.Second;/d; /static function secondPreview()/,+2d; s/Second.Vertex.stride/16/' src/Main.hx
haxeon check --project haxeon.json
[[ ! -e "$second" ]]
rm src/shaders/First.glsl
rmdir src/shaders
cat > src/Main.hx <<'HX'
class Main {
	public static function main():Int
		return 0;
}
HX
sed -i '/"shaderVariants"/d' haxeon.json
haxeon check --project haxeon.json
[[ ! -e "$first" ]]
rg -qF "$output/shaders/LibraryQuad.hx" "$output/shaders.sources"
mkdir "$work/stock-haxe"
cat > "$work/stock-haxe/Main.hx" <<'HX'
@:value
@:repr("C")
@:assertLayout(4, "x", 0)
class Record {
	public var x:Int;
}

class Main {
	static function main() {}
}
HX
"$root/.tools/haxe/haxe" -cp "$work/stock-haxe" -main Main --interp
echo "PASS: project and library shader discovery, variants, target filtering, compute targets, cache reuse, include invalidation, diagnostics, missing driver, and removal"
