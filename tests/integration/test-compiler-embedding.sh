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
import compiler.Compiler.CompileResult;
import sys.thread.Thread;
import sys.thread.Mutex;

class Completion {
    public var done:Bool = false;
    public var build:Null<CompileResult>;
    public var error:Null<String>;
    public var mutex:Mutex = new Mutex();
    public function new() {}
}

function main():Int {
    var compiler = new Compiler(null, CompilerIntrinsics.configuration());
    compiler.enablePublicationTracking();
    compiler.update("Helper.hx", "class Helper { public static function answer(value:Int = 42):Int return value; }");
    compiler.update("Probe.hx", "class Box { public static function answer():Int return 42; } function main():Int return Box.answer() + Helper.answer(0);");
    var build = compiler.compile("Probe");
    var id = build.functionIds.get("main");
    if (id == null) throw "compiled entry has no stable function ID";
    var module = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity);
    var answer = Runtime.callInt(module, id);
    Runtime.dispose(module);
    compiler.acknowledgePublication(build.revision);
    if (answer != 42) throw "embedded compiler/runtime returned the wrong answer";
    compiler.update("Probe.hx", "class Box { public static function answer():Int return 43; } function main():Int return Box.answer() + Helper.answer(0);");
    var completion = new Completion();
    Thread.create(function() {
        try {
            var generated = compiler.compile("Probe");
            completion.mutex.acquire();
            completion.build = generated;
        } catch (error:Dynamic) {
            completion.mutex.acquire();
            completion.error = Std.string(error);
        }
        completion.done = true;
        completion.mutex.release();
    });
    var waited = 0;
    while (true) {
        completion.mutex.acquire();
        var done = completion.done;
        completion.mutex.release();
        if (done) break;
        if (waited++ > 10000) throw "incremental compiler thread timed out";
        Sys.sleep(0.001);
    }
    if (completion.error != null) throw completion.error;
    var next = completion.build;
    if (next == null) throw "incremental thread produced no compile result";
    var nextId = next.functionIds.get("main");
    if (nextId == null) throw "incremental entry lost its function ID";
    var replacement = Runtime.load(HlWriter.encode(next.module), next.runtimeIdentity);
    var updated = Runtime.callInt(replacement, nextId);
    Runtime.dispose(replacement);
    if (updated != 43) throw "incremental guest code did not update";
    Sys.println("PASS: package embeds compiler and executes incremental generated code");
    return 0;
}
HX
task_haxeon_home=${HAXEON_HOME:-$repo_dir}
task_haxe=${HAXEON_HAXE:-"$task_haxeon_home/.tools/haxe/haxe"}
HAXEON_HOME="$task_haxeon_home" HAXEON_COMPILER_SOURCE="$repo_dir/src" \
    "$task_haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli \
    run --project "$project_dir/haxeon.json" "$@"
