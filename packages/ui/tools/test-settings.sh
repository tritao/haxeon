#!/usr/bin/env bash
set -euo pipefail

# Settings core tests. They need only the Haxeon toolchain, not the native UI build.
module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}

cd "$module_dir/tests/settings"
exec "$haxeon_dir/scripts/haxeon" run --project haxeon.json
