#!/usr/bin/env bash
# Minimum call duration: by default a profiled run drops calls shorter than 1 us unless a call inside them is kept, and
# counts them per function; --profile-min-call=0 keeps every call.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src"

cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"mincall"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
	static function tiny(i:Int):Int {
		var x = 0;
		for (j in 0...3)
			x += (i + j) % 7;
		return x;
	}

	static function slow(n:Int):Int {
		var x = 0;
		for (i in 0...n)
			x += tiny(i);
		Sys.sleep(0.002);
		return x;
	}

	static function main():Void {
		var total = 0;
		for (frame in 0...10) {
			haxeon.ProfileFrame.mark();
			total += slow(1000);
		}
		haxeon.ProfileFrame.idle();
		Sys.println('min call test $total');
	}
}
HAXE

capture() {
	local name=$1
	shift
	timeout 600s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" "$@" \
		--profile-output "$scratch/$name/profile.hlpc" > "$scratch/$name.log" 2>&1 || {
		cat "$scratch/$name.log" >&2
		exit 1
	}
	grep -q "min call test" "$scratch/$name.log" || {
		cat "$scratch/$name.log" >&2
		exit 1
	}
	"$repo_dir/.tools/hashlink/hlprof-live" export --format perfetto --output "$scratch/$name.json" "$scratch/$name/profile.hlpc" > /dev/null
}

capture all --profile-min-call=0
capture short --profile

python3 - "$scratch" <<'PY'
import collections
import json
import os
import re
import sys

scratch = sys.argv[1]

def calls(name):
    events = json.load(open(os.path.join(scratch, name + ".json"), encoding="utf-8"))
    events = events["traceEvents"] if isinstance(events, dict) else events
    return collections.Counter(e["name"] for e in events if e.get("ph") == "B")

everything, short = calls("all"), calls("short")
assert everything["Main.tiny"] == 10000, everything.most_common(12)
assert everything["Main.slow"] == 10, everything.most_common(12)
# The slow calls outlast the threshold and stay; the tiny calls inside them go. A tiny call can outlast 1 us when the
# thread is preempted, so a few may stay.
assert short["Main.slow"] == 10, short.most_common(12)
assert short["Main.tiny"] < 100, short.most_common(12)
log = open(os.path.join(scratch, "short.log"), encoding="utf-8", errors="replace").read()
dropped = re.search(r"^\s*(\d+)\s+Main\.tiny$", log, re.M)
assert dropped and int(dropped.group(1)) + short["Main.tiny"] == 10000, log
assert "short calls" not in open(os.path.join(scratch, "all.log"), encoding="utf-8", errors="replace").read()
all_size = os.path.getsize(os.path.join(scratch, "all", "profile.hlpc"))
short_size = os.path.getsize(os.path.join(scratch, "short", "profile.hlpc"))
assert short_size * 4 < all_size, (short_size, all_size)
print(f"capture {all_size} bytes with every call, {short_size} bytes without short calls")
PY
echo "PASS: short calls are dropped and counted by default, and kept with --profile-min-call=0"
