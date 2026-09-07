#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-scopes"
dap=(npx --yes @roblourens/dap-cli@0.3.0)

mkdir -p "$repo_dir/out" "$dap_home/config"
make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
cc -shared -fPIC -DHL_NAME\(n\)=realtime_\#\#n -I "$repo_dir/vendor/hashlink/src" \
	"$repo_dir/native/runtime.c" -L "$repo_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$repo_dir/vendor/hashlink" -o "$repo_dir/out/realtime_runtime.hdll"
if [[ ! -d "$adapter_dir/node_modules" ]]; then
	npm --prefix "$adapter_dir" ci --ignore-scripts
fi
if [[ ! -f "$adapter_dir/adapter.js" ]]; then
	(
		cd "$adapter_dir"
		"$tools_dir/haxe/haxe" build.hxml
	)
fi

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
wait_frame() {
	local expected_line=$1 stack status
	for _ in {1..80}; do
		if status=$("${dap[@]}" status --name "$session" 2>/dev/null) &&
			python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status"; then
			stack=$("${dap[@]}" stack --name "$session")
			if ! python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0]; assert f.get("source",{}).get("name")=="DapScopeProbe.hx" and f.get("line")==int(sys.argv[1])' "$expected_line" <<<"$stack"; then
				printf '%s\n' "$stack" >&2
				return 1
			fi
			current_frame=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stackFrames"][0]["id"])' <<<"$stack")
			return
		fi
		sleep 0.1
	done
	echo "Timed out waiting for DapScopeProbe.hx:$expected_line" >&2
	return 1
}

read_locals() {
	local scopes reference
	scopes=$("${dap[@]}" scopes --name "$session" --frame-id "$current_frame")
	reference=$(python3 -c 'import json,sys; print(next(s["variablesReference"] for s in json.load(sys.stdin)["data"]["scopes"] if s["name"]=="Locals"))' <<<"$scopes")
	"${dap[@]}" variables --name "$session" --variables-reference "$reference"
}

"$tools_dir/haxe/haxe" --cwd "$repo_dir" -cp src --run Main "$repo_dir/tests/DapScopeProbe.hx" "$repo_dir/out/dap-scope-probe.hl" >/dev/null
"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" <<'PY'
import json
import sys

root = sys.argv[1]
print(json.dumps({
    "type": "hl",
    "request": "launch",
    "name": "HashLink DAP lexical scopes",
    "cwd": root + "/out",
    "program": root + "/out/dap-scope-probe.hl",
    "hl": root + "/vendor/hashlink/hl",
    "classPaths": [root + "/tests", root + "/.tools/haxe/std"],
    "env": {"LD_LIBRARY_PATH": root + "/vendor/hashlink", "HL_DEBUG_PROTOCOL": "3"},
}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
breakpoints=$("${dap[@]}" breakpoints set --name "$session" --source "$repo_dir/tests/DapScopeProbe.hx" --line 7 10 13 15 20 22)
python3 -c 'import json,sys; points=json.load(sys.stdin)["data"]["breakpoints"]; assert len(points)==6 and all(p["verified"] for p in points)' <<<"$breakpoints"

wait_frame 7
inside=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; matches=[v for v in vs if v["name"]=="value"]; assert len(matches)==1 and matches[0].get("value")=="20", vs; assert any(v["name"]=="inside" and v.get("value")=="21" for v in vs), vs' <<<"$inside"

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame 10
after=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; matches=[v for v in vs if v["name"]=="value"]; assert len(matches)==1 and matches[0].get("value")=="10", vs; assert not any(v["name"]=="inside" for v in vs), vs; assert any(v["name"]=="after" and v.get("value")=="11" for v in vs), vs' <<<"$after"

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame 13
loop=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="index" and v.get("value")=="0" for v in vs), vs; assert any(v["name"]=="loopOnly" and v.get("value")=="30" for v in vs), vs' <<<"$loop"

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame 15
post_loop=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert not any(v["name"] in ("index", "loopOnly") for v in vs), vs' <<<"$post_loop"

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame 20
catch_scope=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="error" for v in vs), vs; assert any(v["name"]=="catchOnly" for v in vs), vs' <<<"$catch_scope"

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame 22
post_catch=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert not any(v["name"] in ("error", "catchOnly") for v in vs), vs' <<<"$post_catch"

echo "PASS: dap-cli reports shadowed, loop, and catch locals only within their lexical scopes"
