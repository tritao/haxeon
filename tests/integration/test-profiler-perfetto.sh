#!/usr/bin/env bash
set -euo pipefail

# Checks CAPTURE.hlpc when given one (recorded with the sampling and alloc sources); otherwise records its own.
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [CAPTURE.hlpc]" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/lib/env.sh"
profiler_tool="${HLPROF_LIVE:-$("$root/scripts/hashlink-path.sh")/hlprof-live}"
scratch=$(mktemp -d /tmp/haxeon-perfetto-XXXXXX)
output_file="$scratch/trace.json"
trap 'rm -rf "$scratch"' EXIT

capture=${1:-}
if [[ -z $capture ]]; then
  mkdir -p "$scratch/src"
  cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"profiler-perfetto-test"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
  cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
  static function main():Void {
    var kept = [];
    var start = Sys.time();
    // Long enough for several samples, with allocations the GC counter and alloc sites see.
    while (Sys.time() - start < 0.5) {
      var chunk = [for (i in 0...256) Std.string(i)];
      if (kept.length < 64) kept.push(chunk);
    }
    Sys.println("perfetto test " + kept.length);
  }
}
HAXE
  capture="$scratch/capture/profile.hlpc"
  haxeon_timeout 60s "$root/scripts/haxeon" run --project "$scratch/haxeon.json" --profile=sampling,alloc \
    --profile-output "$capture" > "$scratch/run.log" 2>&1 || {
      cat "$scratch/run.log" >&2
      exit 1
    }
fi

"$profiler_tool" export --format perfetto --output "$output_file" "$capture"
jq -e '
  (.traceEvents | length > 0) and
  any(.traceEvents[]; .ph == "C" and .name == "HashLink GC" and (.args.allocation_bytes_per_second != null)) and
  any(.traceEvents[]; .ph == "M" and .name == "thread_name") and
  any(.traceEvents[]; .cat == "hl.sample" and (.args.stack | contains("+0x"))) and
  any(.traceEvents[]; .cat == "hl.alloc" and (.args.estimated_bytes > 0))
' "$output_file" >/dev/null
# An allocation sample carries the Haxe frames that allocated, not only the allocator: Main.main builds every chunk.
if [[ -z ${1:-} ]]; then
  jq -e 'any(.traceEvents[]; .cat == "hl.alloc" and (.args.stack | contains("Main.main")))' "$output_file" >/dev/null
  # report --alloc ranks those bytes by function.
  "$profiler_tool" report --alloc "$capture" > "$scratch/alloc-report.txt"
  grep -q "^ranking estimated allocated bytes" "$scratch/alloc-report.txt"
  grep -q "Main.main" "$scratch/alloc-report.txt"
  # report --alloc --types ranks the allocated types: the program builds Strings and arrays of them.
  "$profiler_tool" report --alloc --types "$capture" > "$scratch/alloc-types.txt"
  grep -q "^ranking allocated types" "$scratch/alloc-types.txt"
  grep -qw "String" "$scratch/alloc-types.txt"
  grep -qw "array" "$scratch/alloc-types.txt"
  jq -e 'any(.traceEvents[]; .cat == "hl.alloc" and .args.type == "String")' "$output_file" >/dev/null
fi
echo "PASS: Perfetto export contains counters, threads, native frames, and allocation sites with their Haxe frames"
