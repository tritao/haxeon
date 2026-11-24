#!/usr/bin/env bash
# Generates the shader module the GPU page quotes, from a copy of the GPU basics guide's triangle, into site/generated.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work="$root/out/site-gpu-modules/triangle"
destination="$root/site/generated/gpu"

rm -rf "$work"
mkdir -p "$(dirname "$work")"
cp -R "$root/docs/guides/examples/06-gpu-basics/triangle" "$work"
"$root/scripts/haxeon" check --project "$work/haxeon.toml"
mkdir -p "$destination"
cp "$work/build/host/generated/shaders/Triangle.hx" "$destination/Triangle.hx"
