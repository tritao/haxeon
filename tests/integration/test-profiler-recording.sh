#!/usr/bin/env bash
# Recording controls: --profile-start=manual opens the session paused, haxeon.ProfileRecording starts, pauses and
# resumes it, and the capture holds only the calls made while recording.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src"

cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"rec"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
	static function work(n:Int):Int {
		var x = 0;
		for (i in 0...n)
			x += i % 7;
		return x;
	}

	static function frames(count:Int):Int {
		var total = 0;
		for (i in 0...count) {
			haxeon.ProfileFrame.mark();
			total += work(20000);
			Sys.sleep(0.005);
		}
		return total;
	}

	static function main():Void {
		var total = frames(20);
		var started = haxeon.ProfileRecording.start();
		total += frames(25);
		var paused = haxeon.ProfileRecording.pause();
		total += frames(20);
		var resumed = haxeon.ProfileRecording.toggle();
		total += frames(20);
		haxeon.ProfileFrame.idle();
		Sys.println('recording test $total $started $paused $resumed ${haxeon.ProfileRecording.recording()}');
	}
}
HAXE

timeout 600s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile-start=manual \
	--profile-output "$scratch/capture/profile.hlpc" > "$scratch/run.log" 2>&1 || {
	cat "$scratch/run.log" >&2
	exit 1
}
grep -q "recording test [0-9]* true true true true" "$scratch/run.log" || {
	cat "$scratch/run.log" >&2
	exit 1
}
"$repo_dir/.tools/hashlink/hlprof-live" export --format perfetto --output "$scratch/trace.json" "$scratch/capture/profile.hlpc"
python3 - "$scratch/trace.json" <<'PY'
import collections
import json
import sys

events = json.load(open(sys.argv[1], encoding="utf-8"))
events = events["traceEvents"] if isinstance(events, dict) else events
counts = collections.Counter(e["name"] for e in events if e.get("ph") == "B")
# 25 frames before the pause and 20 after the resume; the 20 before start and the 20 while paused are not recorded.
assert counts["Main.work"] == 45, counts.most_common(12)
assert counts["Main.frames"] == 2, counts.most_common(12)
PY
echo "PASS: a manual-start session records only while the program has recording on"
