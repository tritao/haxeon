#!/usr/bin/env bash
set -euo pipefail
example_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$example_dir/../.." && pwd)"}
action=${1:---test}
case "$action" in
    --build) exec "$haxeon_dir/scripts/haxeon" build --project "$example_dir/haxeon.json" ;;
    --run) exec "$haxeon_dir/scripts/haxeon" run --project "$example_dir/haxeon.json" ;;
    --test) exec "$haxeon_dir/scripts/haxeon" run --project "$example_dir/tests/haxeon.json" ;;
    *) echo "usage: test-audio-lab.sh [--build|--run|--test]" >&2; exit 2 ;;
esac
