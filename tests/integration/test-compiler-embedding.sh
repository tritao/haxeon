#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-embedding.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT
mkdir -p "$project_dir/src"
python3 - "$repo_dir" "$project_dir" <<'PY'
import json, sys
from pathlib import Path
repo, project = map(Path, sys.argv[1:])
manifest = {
    "version": 1, "package": {"name": "embedding-test"}, "entry": "Main",
    "sourceRoots": ["src"], "scopeSourceRoots": False,
    "dependencies": {"haxeon-compiler": {"path": str(repo / "embed")}}
}
(project / "haxeon.json").write_text(json.dumps(manifest) + "\n")
PY
cp "$repo_dir/tests/fixtures/self-hosting/Main.hx" "$project_dir/src/Main.hx"
task_haxeon_home=${HAXEON_HOME:-$repo_dir}
task_haxe=${HAXEON_HAXE:-"$task_haxeon_home/.tools/haxe/haxe"}
HAXEON_HOME="$task_haxeon_home" HAXEON_COMPILER_SOURCE="$repo_dir/src" \
    "$task_haxe" --cwd "$repo_dir" -cp "$repo_dir/src" -cp "$repo_dir/lib/haxeon-io" --run tools.HaxeonCli \
    run --project "$project_dir/haxeon.json" "$@"

# The library must not replace the consumer's entry with its own compiler CLI Main.
source_manifest="$project_dir/build/host/main.hl.sources.txt"
if rg -F -x -q "$repo_dir/src/Main.hx" "$source_manifest"; then
    echo "compiler library must exclude command-line Main from explicit consumer inputs" >&2
    exit 1
fi
rg -F -x -q "$project_dir/src/Main.hx" "$source_manifest"
