#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-stepping"
dap=(npx --yes @roblourens/dap-cli@0.3.0)

mkdir -p "$repo_dir/out" "$dap_home/config"
make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
cc -shared -fPIC -DHL_NAME\(n\)=realtime_\#\#n -I "$repo_dir/vendor/hashlink/src" \
	"$repo_dir/native/runtime.c" -L "$repo_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$repo_dir/vendor/hashlink" -o "$repo_dir/out/realtime_runtime.hdll"
if [[ ! -d "$adapter_dir/node_modules" ]]; then
	npm --prefix "$adapter_dir" ci --ignore-scripts
fi
(
	cd "$adapter_dir"
	PATH="$tools_dir/haxe:$PATH" \
		LD_LIBRARY_PATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu" \
		NEKOPATH="$tools_dir/neko-runtime/root/usr/lib/x86_64-linux-gnu/neko" haxe build.hxml
)

python3 - "$dap_home/config/adapters.json" "$adapter_dir" <<'PY'
import json
import sys

target, adapter = sys.argv[1:]
with open(target, "w", encoding="utf-8") as output:
    json.dump({
        "adapters": {
            "hashlink": {
                "id": "hashlink",
                "label": "HashLink Debug Adapter",
                "transport": {
                    "kind": "stdio",
                    "command": "node",
                    "args": [adapter + "/adapter.js"],
                    "cwd": adapter,
                },
                "launchDefaults": {"type": "hl", "request": "launch"},
            }
        },
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

current_frame=
current_stack=
wait_frame() {
	local expected_function=$1 expected_line=$2 stack status
	for _ in {1..100}; do
		if status=$("${dap[@]}" status --name "$session" 2>/dev/null) &&
			python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status"; then
			stack=$("${dap[@]}" stack --name "$session")
			if python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0]; raise SystemExit(0 if f.get("source",{}).get("name")=="DapSteppingProbe.hx" and f.get("line")==int(sys.argv[2]) else 1)' "$expected_function" "$expected_line" <<<"$stack"; then
				current_stack=$stack
				current_frame=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stackFrames"][0]["id"])' <<<"$stack")
				return
			fi
		fi
		sleep 0.05
	done
	echo "Timed out waiting for $expected_function at DapSteppingProbe.hx:$expected_line" >&2
	printf '%s\n' "${stack:-no stack response}" >&2
	return 1
}

read_locals() {
	local scopes reference
	scopes=$("${dap[@]}" scopes --name "$session" --frame-id "$current_frame")
	reference=$(python3 -c 'import json,sys; print(next(s["variablesReference"] for s in json.load(sys.stdin)["data"]["scopes"] if s["name"]=="Locals"))' <<<"$scopes")
	"${dap[@]}" variables --name "$session" --variables-reference "$reference"
}

if [[ "${SKIP_DAP_BUILD:-0}" != 1 ]]; then
	"$tools_dir/haxe/haxe" --cwd "$repo_dir" -cp src --run Main "$repo_dir/tests/DapSteppingProbe.hx" "$repo_dir/out/dap-stepping-probe.hl" >/dev/null
fi
"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" <<'PY'
import json
import sys

root = sys.argv[1]
print(json.dumps({
    "type": "hl",
    "request": "launch",
    "name": "HashLink DAP stepping",
    "cwd": root + "/out",
    "program": root + "/out/dap-stepping-probe.hl",
    "hl": root + "/vendor/hashlink/hl",
    "classPaths": [root + "/tests", root + "/.tools/haxe/std"],
    "env": {"LD_LIBRARY_PATH": root + "/vendor/hashlink", "HL_DEBUG_PROTOCOL": "3"},
}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
breakpoint=$("${dap[@]}" breakpoints set --name "$session" --source "$repo_dir/tests/DapSteppingProbe.hx" --line 9)
python3 -c 'import json,sys; assert json.load(sys.stdin)["data"]["breakpoints"][0]["verified"]' <<<"$breakpoint"

wait_frame DapSteppingProbe.main 9

"${dap[@]}" next --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 10
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="seed" and v.get("value")=="20" for v in vs), vs' <<<"$locals"

"${dap[@]}" step-in --name "$session" >/dev/null
wait_frame DapSteppingProbe.callee 2
python3 -c 'import json,sys; frames=json.load(sys.stdin)["data"]["stackFrames"]; assert len(frames)>=2 and frames[1].get("source",{}).get("name")=="DapSteppingProbe.hx" and frames[1].get("line")==10, frames' <<<"$current_stack"
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="input" and v.get("value")=="20" for v in vs), vs' <<<"$locals"

"${dap[@]}" next --name "$session" >/dev/null
wait_frame DapSteppingProbe.callee 3
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="doubled" and v.get("value")=="40" for v in vs), vs' <<<"$locals"

"${dap[@]}" next --name "$session" >/dev/null
wait_frame DapSteppingProbe.callee 4
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="result" and v.get("value")=="41" for v in vs), vs' <<<"$locals"

"${dap[@]}" step-out --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 10

"${dap[@]}" next --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 11
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="answer" and v.get("value")=="41" for v in vs), vs' <<<"$locals"

"${dap[@]}" next --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 12
"${dap[@]}" next --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 14
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="answer" and v.get("value")=="42" for v in vs), vs' <<<"$locals"
loop_breakpoint=$("${dap[@]}" breakpoints set --name "$session" --source "$repo_dir/tests/DapSteppingProbe.hx" --line 15)
python3 -c 'import json,sys; assert json.load(sys.stdin)["data"]["breakpoints"][0]["verified"]' <<<"$loop_breakpoint"
"${dap[@]}" next --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 15
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="index" and v.get("value")=="0" for v in vs), vs' <<<"$locals"
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="answer" and v.get("value")=="42" for v in vs), vs' <<<"$locals"

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 15
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="index" and v.get("value")=="1" for v in vs), vs' <<<"$locals"
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="answer" and v.get("value")=="42" for v in vs), vs' <<<"$locals"

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame DapSteppingProbe.main 15
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="index" and v.get("value")=="2" for v in vs), vs' <<<"$locals"
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="answer" and v.get("value")=="43" for v in vs), vs' <<<"$locals"

echo "PASS: dap-cli next, stepIn, and stepOut preserve source lines, frames, branches, loops, and locals"
