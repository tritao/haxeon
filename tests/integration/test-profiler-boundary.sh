#!/usr/bin/env bash
# Boundary calls (Linux x86-64): an instrumented run records calls from the program's own objects into system libraries as
# slices named after the function (`libc!nanosleep`), nested under the Haxe call that made them, and keeps them under the
# default short-call dropping. `imports=none` turns them off.
set -euo pipefail

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
	echo "SKIP: boundary hooks are Windows x64 and Linux x86-64 only"
	exit 0
fi

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src"

cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"boundary"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
	// Loops keep these from being inlined into main, so each is a probed call the boundary slices nest under.
	static function pause():Void {
		for (i in 0...2)
			Sys.sleep(0.005);
	}

	static function readBack(path:String):Int {
		var length = 0, reads = 0;
		while (reads < 1) {
			length += sys.io.File.getContent(path).length;
			reads++;
		}
		return length;
	}

	static function main():Void {
		var path = Sys.getEnv("BOUNDARY_DIR") + "/boundary.txt";
		sys.io.File.saveContent(path, "hello boundary");
		var total = 0;
		for (i in 0...5) {
			haxeon.ProfileFrame.mark();
			pause();
			total += readBack(path);
		}
		haxeon.ProfileFrame.idle();
		Sys.println("boundary test " + total);
	}
}
HAXE

record() {
	local name=$1 trace=$2
	shift 2
	BOUNDARY_DIR="$scratch" timeout 600s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile "$@" \
		--profile-output "$scratch/$name/profile.hlpc" > "$scratch/$name.log" 2>&1 || {
		cat "$scratch/$name.log" >&2
		exit 1
	}
	grep -q "boundary test 70" "$scratch/$name.log" || {
		cat "$scratch/$name.log" >&2
		exit 1
	}
	"$repo_dir/.tools/hashlink/hlprof-live" export --format perfetto --output "$scratch/$trace" "$scratch/$name/profile.hlpc"
}

record hooked trace.json
python3 - "$scratch/trace.json" <<'PY'
import collections
import json
import sys

events = json.load(open(sys.argv[1], encoding="utf-8"))
events = events["traceEvents"] if isinstance(events, dict) else events
counts = collections.Counter(e["name"] for e in events if e.get("ph") == "B" and e["name"].startswith("libc!"))
sleeps = sum(counts[name] for name in ("libc!nanosleep", "libc!clock_nanosleep", "libc!usleep"))
assert sleeps >= 10, ("sleeps", counts)
# The file is opened and closed once to write it and five times to read it back.
assert counts["libc!fopen"] == 6 and counts["libc!fclose"] == 6, counts
# Each boundary call nests under the Haxe call that made it.
ancestors, stacks = collections.defaultdict(set), collections.defaultdict(list)
for e in events:
    if e.get("ph") == "B":
        stack = stacks[e["tid"]]
        if e["name"].startswith("libc!"):
            ancestors[e["name"]].update(stack)
        stack.append(e["name"])
    elif e.get("ph") == "E" and stacks[e["tid"]]:
        stacks[e["tid"]].pop()
sleep_names = [name for name in ("libc!nanosleep", "libc!clock_nanosleep", "libc!usleep") if counts[name]]
assert any("Main.pause" in ancestors[name] for name in sleep_names), ancestors
assert "Main.readBack" in ancestors["libc!fopen"] and "Main.main" in ancestors["libc!fopen"], ancestors
PY

# With "imports": "none", nothing is hooked: the same run has no boundary slices.
python3 - "$scratch/haxeon.json" <<'PY'
import json
import sys

path = sys.argv[1]
manifest = json.load(open(path))
manifest["instrument"] = {"boundary": {"imports": "none"}}
json.dump(manifest, open(path, "w"))
PY
record unhooked trace-none.json
python3 - "$scratch/trace-none.json" <<'PY'
import json
import sys

events = json.load(open(sys.argv[1], encoding="utf-8"))
events = events["traceEvents"] if isinstance(events, dict) else events
hooked = sorted({e["name"] for e in events if e.get("ph") == "B" and e["name"].startswith("libc!")})
assert not hooked, hooked
PY
echo "PASS: boundary calls are recorded as slices named after the library function, nested under the Haxe calls that made them, and off with imports none"
