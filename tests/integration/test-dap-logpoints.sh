#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-logpoints"
dap=(npx --yes @roblourens/dap-cli@0.3.0)

mkdir -p "$repo_dir/out" "$dap_home/config"
make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
cc -shared -fPIC -DHL_NAME\(n\)=realtime_\#\#n -I "$repo_dir/vendor/hashlink/src" \
	"$repo_dir/native/runtime.c" -L "$repo_dir/vendor/hashlink" -lhl -lffi -ldl \
	-Wl,-rpath,"$repo_dir/vendor/hashlink" -o "$repo_dir/out/haxeon_runtime.hdll"
if [[ ! -d "$adapter_dir/node_modules" ]]; then npm --prefix "$adapter_dir" ci --ignore-scripts; fi
(
	cd "$adapter_dir"
	PATH="$tools_dir/haxe:$PATH" \
		LD_LIBRARY_PATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu" \
		NEKOPATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu/neko" haxe build.hxml
)
"$tools_dir/haxe/haxe" --cwd "$repo_dir" -cp src --run Main \
	"$repo_dir/tests/dap/DapLogpointProbe.hx" "$repo_dir/out/dap-logpoint-probe.hl" >/dev/null

python3 - "$dap_home/config/adapters.json" "$adapter_dir" <<'PY'
import json
import sys

target, adapter = sys.argv[1:]
with open(target, "w", encoding="utf-8") as output:
    json.dump({
        "adapters": {"hashlink": {
            "id": "hashlink", "label": "HashLink Debug Adapter",
            "transport": {"kind": "stdio", "command": "node", "args": [adapter + "/adapter.js"], "cwd": adapter},
            "launchDefaults": {"type": "hl", "request": "launch"},
        }},
        "launchConfigTypeMap": {"hl": "hashlink"},
    }, output)
PY

export DAP_CLI_HOME="$dap_home"
cleanup() {
	"${dap[@]}" stop --name "$session" >/dev/null 2>&1 || true
	"${dap[@]}" close "$session" >/dev/null 2>&1 || true
	"${dap[@]}" stop-controller >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" <<'PY'
import json
import sys

root = sys.argv[1]
print(json.dumps({
    "type": "hl", "request": "launch", "name": "HashLink DAP logpoints",
    "cwd": root + "/out", "program": root + "/out/dap-logpoint-probe.hl", "hl": root + "/vendor/hashlink/hl",
    "classPaths": [root + "/tests", root + "/.tools/haxe/std"],
    "env": {"LD_LIBRARY_PATH": root + "/vendor/hashlink", "HL_DEBUG_PROTOCOL": "3"},
}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
breakpoint=$("${dap[@]}" breakpoints set --name "$session" \
	--source "$repo_dir/tests/dap/DapLogpointProbe.hx" --line 6 \
	--log-message 'iteration {index}: doubled={{ {doubled} }}, missing={missingValue}')
python3 -c 'import json,sys; point=json.load(sys.stdin)["data"]["breakpoints"][0]; assert point["verified"] and point["line"]==6, point' <<<"$breakpoint"

for _ in {1..100}; do
	status=$("${dap[@]}" status --name "$session" 2>/dev/null || true)
	if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="terminated" else 1)' <<<"$status" 2>/dev/null; then
		break
	fi
	sleep 0.05
done
events=$("${dap[@]}" events --name "$session" --include output,stopped --limit 100)
python3 -c '
import json, sys
events = json.load(sys.stdin)["data"]["events"]
assert not any(event["event"] == "stopped" for event in events), events
output = "".join(event.get("body", {}).get("output", "") for event in events if event["event"] == "output")
for expected in (
    "iteration 0: doubled={ 0 }, missing=<error:",
    "iteration 1: doubled={ 2 }, missing=<error:",
    "iteration 2: doubled={ 4 }, missing=<error:",
):
    assert expected in output, (expected, output)
' <<<"$events"

echo "PASS: DAP logpoints interpolate expressions, report evaluation errors, and continue without stopping"
