#!/usr/bin/env bash
# Generates the GPU examples' shader modules the GPU page quotes, into site/generated.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project="$root/packages/gpu/examples/triangle"
destination="$root/site/generated/gpu"

"$root/scripts/haxeon" check --project "$project/haxeon.json"
mkdir -p "$destination"
cp "$project/build/host/generated/shaders/Triangle.hx" "$destination/Triangle.hx"
