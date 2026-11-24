#!/usr/bin/env bash
set -euo pipefail

gpu=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(cd "$gpu/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
cp "$gpu/tests/shaders/"{Fixture.glsl,shaders.json,Fixture.hx} "$fixture/"
"$("$root/scripts/shader-tool-path.sh")" "$fixture/shaders.json" "$@"
python3 "$gpu/tools/generate-shader-haxe.py" "$fixture/fixture.reflection.json" fixture "$fixture/Fixture.hx" --package shaders --check
