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
  static function main():Void Sys.println("profile capture test");
}
HAXE

timeout 20s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile \
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
assert (capture / manifest["artifacts"]["bytecode"]).read_bytes() == (capture.parent / "build/host/main.hl").read_bytes()
assert (capture / manifest["artifacts"]["profile"]).stat().st_size > 0
PY
"$repo_dir/.tools/hashlink/hlprof-live" report "$scratch/capture/profile.hlpc" > "$scratch/report.log"

# A process can exit after profiler configuration but before the first sample
# chunk. That is still a complete, valid capture with cursor zero.
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
echo "PASS: profiled run completes and empty capture reports cleanly"
