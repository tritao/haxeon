#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-function-breakpoints"
top_level_session="hl-dap-top-level-function"
dap=(npx --yes @roblourens/dap-cli@0.3.0)

mkdir -p "$repo_dir/out" "$dap_home/config"
make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
if [[ ! -d "$adapter_dir/node_modules" ]]; then npm --prefix "$adapter_dir" ci --ignore-scripts; fi
(
	cd "$adapter_dir"
	PATH="$tools_dir/haxe:$PATH" \
		LD_LIBRARY_PATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu" \
		NEKOPATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu/neko" haxe build.hxml
)
"$tools_dir/haxe/haxe" "$repo_dir/tests/hxml/dap-function-probe.hxml"

python3 - "$dap_home/config/adapters.json" "$adapter_dir" <<'PY'
import json, sys
target, adapter = sys.argv[1:]
with open(target, "w", encoding="utf-8") as output:
    json.dump({"adapters":{"hashlink":{"id":"hashlink","label":"HashLink Debug Adapter","transport":{"kind":"stdio","command":"node","args":[adapter+"/adapter.js"],"cwd":adapter},"launchDefaults":{"type":"hl","request":"launch"}}},"launchConfigTypeMap":{"hl":"hashlink"}}, output)
PY

export DAP_CLI_HOME="$dap_home"
cleanup() {
	"${dap[@]}" stop --name "$session" >/dev/null 2>&1 || true
	"${dap[@]}" close "$session" >/dev/null 2>&1 || true
	"${dap[@]}" stop --name "$top_level_session" >/dev/null 2>&1 || true
	"${dap[@]}" close "$top_level_session" >/dev/null 2>&1 || true
	"${dap[@]}" stop-controller >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" <<'PY'
import json, sys
root = sys.argv[1]
print(json.dumps({"type":"hl","request":"launch","name":"HashLink DAP function breakpoints","cwd":root,"program":root+"/out/dap-function-probe.hl","hl":root+"/vendor/hashlink/hl","classPaths":[root+"/tests",root+"/.tools/haxe/std"],"env":{"LD_LIBRARY_PATH":root+"/vendor/hashlink","HL_DEBUG_PROTOCOL":"3"}}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
result=$("${dap[@]}" request --name "$session" setFunctionBreakpoints --json \
	'{"breakpoints":[{"name":"DapFunctionWorker.tick","condition":"value == 2"},{"name":"tick"},{"name":"Missing.worker"}]}')
python3 -c '
import json, sys
points=json.load(sys.stdin)["data"]["breakpoints"]
assert points[0]["verified"], points
assert not points[1]["verified"] and "ambiguous" in points[1]["message"], points
assert not points[2]["verified"] and "not found" in points[2]["message"], points
' <<<"$result"

stopped=false
for _ in {1..100}; do
	status=$("${dap[@]}" status --name "$session" 2>/dev/null || true)
	if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status" 2>/dev/null; then
		stopped=true
		break
	fi
	sleep 0.05
done
if [[ "$stopped" != true ]]; then echo "Function breakpoint did not stop" >&2; exit 1; fi
stack=$("${dap[@]}" stack --name "$session")
python3 -c 'import json,sys; frame=json.load(sys.stdin)["data"]["stackFrames"][0]; assert frame["name"]=="DapFunctionWorker.tick", frame' <<<"$stack"
evaluated=$("${dap[@]}" evaluate --name "$session" --frame-id 0 --context watch --expression value)
python3 -c 'import json,sys; data=json.load(sys.stdin)["data"]; assert data["result"]=="2", data' <<<"$evaluated"
"${dap[@]}" continue --name "$session" >/dev/null

for _ in {1..100}; do
	status=$("${dap[@]}" status --name "$session" 2>/dev/null || true)
	if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="terminated" else 1)' <<<"$status" 2>/dev/null; then
		break
	fi
	sleep 0.05
done
if ! python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="terminated" else 1)' <<<"$status"; then
	echo "Target did not terminate after the conditional function breakpoint" >&2
	exit 1
fi

"${dap[@]}" close "$session" >/dev/null
"$tools_dir/haxe/haxe" --cwd "$repo_dir" -cp src --run Main \
	"$repo_dir/tests/DapTopLevelFunctionProbe.hx" "$repo_dir/out/dap-top-level-function.hl" >/dev/null
top_level_launch=$(python3 - "$repo_dir" <<'PY'
import json, sys
root = sys.argv[1]
print(json.dumps({"type":"hl","request":"launch","name":"Top-level function identity","cwd":root+"/out","program":root+"/out/dap-top-level-function.hl","hl":root+"/vendor/hashlink/hl","classPaths":[root+"/tests",root+"/.tools/haxe/std"],"env":{"LD_LIBRARY_PATH":root+"/vendor/hashlink","HL_DEBUG_PROTOCOL":"3"}}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$top_level_session" --json "$top_level_launch" >/dev/null
result=$("${dap[@]}" request --name "$top_level_session" setFunctionBreakpoints --json '{"breakpoints":[{"name":"worker"}]}')
python3 -c 'import json,sys; point=json.load(sys.stdin)["data"]["breakpoints"][0]; assert point["verified"], point' <<<"$result"
for _ in {1..100}; do
	status=$("${dap[@]}" status --name "$top_level_session" 2>/dev/null || true)
	if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status" 2>/dev/null; then break; fi
	sleep 0.05
done
if ! python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status"; then
	echo "Top-level function breakpoint did not stop" >&2
	exit 1
fi
stack=$("${dap[@]}" stack --name "$top_level_session")
python3 -c 'import json,sys; frame=json.load(sys.stdin)["data"]["stackFrames"][0]; assert frame["source"]["name"]=="DapTopLevelFunctionProbe.hx" and frame["name"].endswith("DapTopLevelFunctionProbe.worker"), frame' <<<"$stack"

echo "PASS: DAP function breakpoints resolve methods and explicit top-level identities, reject ambiguous names, and honor conditions"
