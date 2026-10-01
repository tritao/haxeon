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
cat > "$project_dir/src/Main.hx" <<'HX'
import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import runtime.Runtime;

function main():Int {
    var compiler = new Compiler(null, CompilerIntrinsics.configuration());
    compiler.update("Probe.hx", "function main():Int return 42;");
    var build = compiler.compile("Probe");
    var id = build.functionIds.get("main");
    if (id == null) throw "compiled entry has no stable function ID";
    var module = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity);
    var answer = Runtime.callInt(module, id);
    Runtime.dispose(module);
    if (answer != 42) throw "embedded compiler/runtime returned the wrong answer";
    Sys.println("PASS: package embeds compiler and executes generated code");
    return 0;
}
HX
task_haxeon_home=${HAXEON_HOME:-$repo_dir}
task_haxe=${HAXEON_HAXE:-"$task_haxeon_home/.tools/haxe/haxe"}
HAXEON_HOME="$task_haxeon_home" HAXEON_COMPILER_SOURCE="$repo_dir/src" \
    "$task_haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli \
    run --project "$project_dir/haxeon.json" "$@"
