#!/usr/bin/env bash
# Sample the main thread while census symbol resolution owns the module registry lock.
set -euo pipefail
[[ $(uname -s) == Linux ]] || { echo 'SKIP: Linux interposition test'; exit 0; }
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-profiler-census-XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src"
cc -shared -fPIC -O2 "$repo_dir/tests/native/profiler_registry_delay.c" -ldl -o "$scratch/delay.so"
cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"profiler-census-sampling"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
  static function allocate(n:Int):Array<Int> {
    var result:Array<Int> = [];
    for (i in 0...n) result.push(i);
    return result;
  }
  static function main():Void {
    Sys.putEnv("HL_TEST_REGISTRY_DELAY_ACTIVE", "1");
    hl.Gc.censusStart(128);
    var keep:Array<Array<Int>> = [];
    for (i in 0...30) {
      keep.push(allocate(100));
      hl.Gc.censusDump(Sys.args()[0]);
    }
    hl.Gc.censusStop();
    Sys.println("census finished " + keep.length);
  }
}
HAXE
# Build separately so LD_PRELOAD applies to the sampled runtime, not the compiler.
timeout 180s "$repo_dir/scripts/haxeon" build --project "$scratch/haxeon.json" > "$scratch/build.log" 2>&1 || { cat "$scratch/build.log" >&2; exit 1; }
export LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
HL_TEST_REGISTRY_DELAY_MARKER="$scratch/entered" LD_PRELOAD="$scratch/delay.so${LD_PRELOAD:+:$LD_PRELOAD}" timeout 40s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" \
  --profile=sampling --profile-output "$scratch/capture/profile.hlpc" -- "$scratch/census.json" > "$scratch/run.log" 2>&1 || { cat "$scratch/run.log" >&2; echo 'FAIL: sampled census did not finish' >&2; exit 1; }
grep -q 'census finished 30' "$scratch/run.log"
test -s "$scratch/capture/profile.hlpc"
test -s "$scratch/entered" || { echo "FAIL: registry delay was never reached" >&2; exit 1; }
python3 - "$scratch/census.json" <<'PY'
import json,sys
census=json.load(open(sys.argv[1]))
assert census['allocations'] > 0 and census['stacks'], 'census did not capture allocation stacks'
PY
echo 'PASS: sampled census completes while registry sections are delayed'
