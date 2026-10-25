#!/usr/bin/env bash
set -euo pipefail

# A function left out of the instrumentation scope that catches a throw through instrumented calls still closes their
# slices, so calls after the catch do not nest under them.
repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d /tmp/haxeon-excluded-catch-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src"
cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"excluded-catch-test"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build",
 "instrument":{"haxe":{"exclude":["Main.catcher"]},"minCallMicros":0}}
JSON
cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
  static var sink = 0;

  static function thrower(n:Int):Int {
    if (n >= 0) throw "out";
    return n;
  }

  // Loops keep these from being inlined, so each stays a probed call.
  static function middle(n:Int):Int {
    var total = 0;
    for (i in 0...n + 8) total += i * 7 % 5;
    return thrower(n) + total;
  }

  static function catcher():Void {
    try {
      sink += middle(1);
    } catch (e:Dynamic) {
      sink++;
    }
  }

  static function after():Void {
    for (i in 0...8) sink += i % 3;
  }

  static function main():Void {
    catcher();
    after();
    Sys.println("excluded catch test " + sink);
  }
}
HAXE

timeout 60s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile \
  --profile-output "$scratch/capture/profile.hlpc" > "$scratch/run.log" 2>&1 || {
    cat "$scratch/run.log" >&2
    exit 1
  }
"$repo_dir/.tools/hashlink/hlprof-live" export --format perfetto --output "$scratch/trace.json" "$scratch/capture/profile.hlpc"
python3 - "$scratch/trace.json" <<'PY'
import json
import sys

events = json.load(open(sys.argv[1]))
events = events["traceEvents"] if isinstance(events, dict) else events
stacks, seen = {}, set()
for event in sorted((e for e in events if e.get("ph") in ("B", "E")), key=lambda e: e["ts"]):
    stack = stacks.setdefault(event["tid"], [])
    if event["ph"] == "E":
        if stack:
            stack.pop()
        continue
    name = event["name"]
    seen.add(name)
    if name == "Main.after":
        assert "Main.middle" not in stack and "Main.thrower" not in stack, f"Main.after nested under {stack}"
    stack.append(name)
assert {"Main.thrower", "Main.middle", "Main.after"} <= seen, sorted(n for n in seen if n.startswith("Main."))
assert "Main.catcher" not in seen, "the excluded function was probed"
PY
echo "PASS: a catch in a function outside the instrumentation scope closes the slices of the calls its throw skipped"
