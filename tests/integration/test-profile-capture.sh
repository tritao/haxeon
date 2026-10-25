#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d /tmp/haxeon-profile-capture-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src"
cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"profile-capture-test"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
  static function measured(n:Int):Int {
    var total = 0;
    for (i in 0...n) total += i % 3;
    return total;
  }

  static function main():Void {
    haxeon.ProfileCounter.set("capture.test.counter", 7);
    var done = new sys.thread.Lock();
    haxeon.Threads.create("capture.worker", function() {
      measured(1000);
      done.release();
    });
    done.wait();
    Sys.println("profile capture test " + measured(1000));
  }
}
HAXE

# Every call is kept, so the trace shows the short ones this checks for.
timeout 20s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile --profile-min-call=0 \
  --profile-output "$scratch/capture/profile.hlpc" > "$scratch/run.log" 2>&1 || {
    cat "$scratch/run.log" >&2
    exit 1
  }
python3 - "$scratch/capture" <<'PY'
import json
import pathlib
import sys

capture = pathlib.Path(sys.argv[1])
manifest = json.loads((capture / "capture.json").read_text())
assert manifest["kind"] == "haxeon.capture" and manifest["schemaVersion"] == 1
# The default source is instrument, which runs the instrumented build.
assert (capture / manifest["artifacts"]["bytecode"]).read_bytes() == (capture.parent / "build-instrument/host/main.hl").read_bytes()
assert (capture / manifest["artifacts"]["profile"]).stat().st_size > 0
trace = (capture / manifest["artifacts"]["perfetto"]).read_bytes()
assert manifest["artifacts"]["perfetto"] == "profile.pftrace" and b"capture.test.counter" in trace
assert b"Main.measured" in trace
# The session starts before the entry point, so it shows the runtime's startup under a Startup frame.
assert b"Startup" in trace and b"Load bytecode" in trace and b"Compile and link the module" in trace
# A thread named where it starts keeps that name, though it exits before the session's next thread list.
assert b"capture.worker" in trace
PY
"$repo_dir/.tools/hashlink/hlprof-live" report "$scratch/capture/profile.hlpc" > "$scratch/report.log"

# A directory holds one capture: recording the same capture again replaces it,
# and recording a different one into the same directory is refused.
timeout 20s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile \
  --profile-output "$scratch/capture/profile.hlpc" > "$scratch/rerun.log" 2>&1 || {
    cat "$scratch/rerun.log" >&2
    exit 1
  }
if timeout 20s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile \
  --profile-output "$scratch/capture/other.hlpc" > "$scratch/other.log" 2>&1; then
  echo "FAIL: a second capture was recorded into an occupied directory" >&2
  exit 1
fi
rg -q 'already holds another capture' "$scratch/other.log"

# A source list selects what the recorder captures; without instrument, the ordinary build runs.
timeout 20s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile=sampling   --profile-output "$scratch/sampling/profile.hlpc" > "$scratch/sampling.log" 2>&1 || {
    cat "$scratch/sampling.log" >&2
    exit 1
  }
test -s "$scratch/sampling/profile.hlpc" && test -s "$scratch/sampling/profile.pftrace"
cmp -s "$scratch/sampling/profile.hl" "$scratch/build/host/main.hl"
timeout 20s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile=instrument,sampling --profile-min-call=0 --profile-output "$scratch/mixed/profile.hlpc" > "$scratch/mixed.log" 2>&1 || {
    cat "$scratch/mixed.log" >&2
    exit 1
  }
rg -q -a 'Main.measured' "$scratch/mixed/profile.pftrace"

# A process can exit after profiler configuration but before the first sample
# chunk. That is still a complete, valid capture with cursor zero (this hand-built capture is HLPC v1, which stays readable).
python3 - "$scratch/empty.hlpc" <<'PY'
import pathlib
import struct
import sys

pathlib.Path(sys.argv[1]).write_bytes(
    struct.pack("<4sHHIIII", b"HLPC", 1, 24, 0, 1, 1000, 0)
    + struct.pack("<IIQ", 3, 16, 0)
    + struct.pack("<QQ", 0, 0)
)
PY
"$repo_dir/.tools/hashlink/hlprof-live" report "$scratch/empty.hlpc" > "$scratch/empty-report.log"
rg -q 'samples=0' "$scratch/empty-report.log"
echo "PASS: profiled run exports a trace with counters and instrumented calls, keeps one capture per directory, and empty capture reports cleanly"
