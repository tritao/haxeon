#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-watchpoints"
dap=(npx --yes @roblourens/dap-cli@0.3.0)

mkdir -p "$repo_dir/out" "$dap_home/config"
make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
cc -shared -fPIC -DHL_NAME\(n\)=realtime_\#\#n -I "$repo_dir/vendor/hashlink/src" \
	"$repo_dir/native/runtime.c" -L "$repo_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$repo_dir/vendor/hashlink" -o "$repo_dir/out/realtime_runtime.hdll"
if [[ ! -d "$adapter_dir/node_modules" ]]; then npm --prefix "$adapter_dir" ci --ignore-scripts; fi
(
	cd "$adapter_dir"
	PATH="$tools_dir/haxe:$PATH" \
		LD_LIBRARY_PATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu" \
		NEKOPATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu/neko" haxe build.hxml
)
"$tools_dir/haxe/haxe" --cwd "$repo_dir" -cp src --run Main \
	"$repo_dir/tests/dap/DapWatchpointProbe.hx" "$repo_dir/out/dap-watchpoint-probe.hl" >/dev/null

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
    "type": "hl", "request": "launch", "name": "HashLink DAP watchpoints",
    "cwd": root + "/out", "program": root + "/out/dap-watchpoint-probe.hl", "hl": root + "/vendor/hashlink/hl",
    "classPaths": [root + "/tests", root + "/.tools/haxe/std"],
    "env": {"LD_LIBRARY_PATH": root + "/vendor/hashlink", "HL_DEBUG_PROTOCOL": "3"},
}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
breakpoint=$("${dap[@]}" breakpoints set --name "$session" --source "$repo_dir/tests/dap/DapWatchpointProbe.hx" --line 5)
python3 -c 'import json,sys; p=json.load(sys.stdin)["data"]["breakpoints"][0]; assert p["verified"] and p["line"]==5, p' <<<"$breakpoint"

wait_stop() {
	local expected_line=$1 stack status
	for _ in {1..100}; do
		status=$("${dap[@]}" status --name "$session" 2>/dev/null || true)
		if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status" 2>/dev/null; then
			stack=$("${dap[@]}" stack --name "$session")
			if python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0]; assert f.get("source",{}).get("name")=="DapWatchpointProbe.hx" and f.get("line")==int(sys.argv[1])' "$expected_line" <<<"$stack" 2>/dev/null; then
				current_frame=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stackFrames"][0]["id"])' <<<"$stack")
				return
			fi
		fi
		sleep 0.05
	done
	echo "Timed out waiting for DapWatchpointProbe.hx:$expected_line" >&2
	printf '%s\n' "${stack:-no stack response}" >&2
	return 1
}

read_locals() {
	local scopes
	scopes=$("${dap[@]}" scopes --name "$session" --frame-id "$current_frame")
	locals_ref=$(python3 -c 'import json,sys; print(next(s["variablesReference"] for s in json.load(sys.stdin)["data"]["scopes"] if s["name"]=="Locals"))' <<<"$scopes")
	locals=$("${dap[@]}" variables --name "$session" --variables-reference "$locals_ref")
}

wait_stop 5
read_locals
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="watched" and v["value"]=="0" for v in vs), vs' <<<"$locals"
info=$("${dap[@]}" request --name "$session" dataBreakpointInfo --json "{\"variablesReference\":$locals_ref,\"name\":\"watched\"}")
data_id=$(python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert d["dataId"] is not None and ":" in d["dataId"] and d["accessTypes"]==["write"], d; print(d["dataId"])' <<<"$info")
installed=$("${dap[@]}" request --name "$session" setDataBreakpoints --json "{\"breakpoints\":[{\"dataId\":\"$data_id\",\"accessType\":\"write\"}]}")
python3 -c 'import json,sys; points=json.load(sys.stdin)["data"]["breakpoints"]; assert len(points)==1 and points[0]["verified"], points' <<<"$installed"
"${dap[@]}" request --name "$session" setBreakpoints \
	--json "{\"source\":{\"path\":\"$repo_dir/tests/dap/DapWatchpointProbe.hx\"},\"breakpoints\":[]}" >/dev/null

"${dap[@]}" continue --name "$session" >/dev/null
for expected in 10 20 30; do
	wait_stop 6
	read_locals
	python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="watched" and v["value"]==sys.argv[1] for v in vs), vs' "$expected" <<<"$locals"
	if [[ "$expected" == 10 ]]; then
		"${dap[@]}" next --name "$session" >/dev/null
		wait_stop 4
	fi
	if [[ "$expected" != 30 ]]; then
		"${dap[@]}" continue --name "$session" >/dev/null
	fi
done

cleared=$("${dap[@]}" request --name "$session" setDataBreakpoints --json '{"breakpoints":[]}')
python3 -c 'import json,sys; assert json.load(sys.stdin)["data"]["breakpoints"]==[]' <<<"$cleared"
rejected=$("${dap[@]}" request --name "$session" setDataBreakpoints --json '{"breakpoints":[{"dataId":"999999","accessType":"write"}]}')
python3 -c 'import json,sys; point=json.load(sys.stdin)["data"]["breakpoints"][0]; assert not point["verified"] and "no longer valid" in point["message"], point' <<<"$rejected"
echo "PASS: DAP local write watchpoint reports repeated mutations and survives stepping"
