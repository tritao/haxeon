#!/usr/bin/env bash
set -euo pipefail

gpu=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(cd "$gpu/../.." && pwd)
app="$gpu/examples/circuit-run/src"
python3 "$root/vendor/nativekit/modules/gpu/tools/shaders.py" "$app/shaders/shaders.json" --check "$@"
python3 "$gpu/tools/generate-shader-haxe.py" "$app/shaders/maze.reflection.json" maze "$app/MazeShader.hx" --check
