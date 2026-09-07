#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-interaction"
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

"$tools_dir/haxe/haxe" --cwd "$repo_dir" -cp src --run Main \
	"$repo_dir/tests/dap/DapInteractionProbe.hx" "$repo_dir/out/dap-interaction-probe.hl" >/dev/null
"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" <<'PY'
import json
import sys

root = sys.argv[1]
print(json.dumps({
    "type": "hl",
    "request": "launch",
    "name": "HashLink DAP interaction",
    "cwd": root + "/out",
    "program": root + "/out/dap-interaction-probe.hl",
    "hl": root + "/vendor/hashlink/hl",
    "classPaths": [root + "/tests", root + "/.tools/haxe/std"],
    "env": {"LD_LIBRARY_PATH": root + "/vendor/hashlink", "HL_DEBUG_PROTOCOL": "3"},
}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
breakpoint=$("${dap[@]}" breakpoints set --name "$session" \
	--source "$repo_dir/tests/dap/DapInteractionProbe.hx" --line 6 --condition 'index == 2')
python3 -c 'import json,sys; point=json.load(sys.stdin)["data"]["breakpoints"][0]; assert point["verified"] and point["line"]==6, point' <<<"$breakpoint"

current_frame=
for _ in {1..100}; do
	status=$("${dap[@]}" status --name "$session" 2>/dev/null || true)
	if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status" 2>/dev/null; then
		stack=$("${dap[@]}" stack --name "$session")
		if python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0]; assert f.get("source",{}).get("name")=="DapInteractionProbe.hx" and f.get("line")==6' <<<"$stack" 2>/dev/null; then
			current_frame=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stackFrames"][0]["id"])' <<<"$stack")
			break
		fi
	fi
	sleep 0.05
done
if [[ -z "$current_frame" ]]; then
	echo "Conditional breakpoint did not stop at DapInteractionProbe.hx:6" >&2
	exit 1
fi

scopes=$("${dap[@]}" scopes --name "$session" --frame-id "$current_frame")
locals_ref=$(python3 -c 'import json,sys; print(next(s["variablesReference"] for s in json.load(sys.stdin)["data"]["scopes"] if s["name"]=="Locals"))' <<<"$scopes")
locals=$("${dap[@]}" variables --name "$session" --variables-reference "$locals_ref")
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="index" and v["value"]=="2" for v in vs) and any(v["name"]=="candidate" and v["value"]=="6" for v in vs), vs' <<<"$locals"

evaluated=$("${dap[@]}" evaluate --name "$session" --frame-id "$current_frame" --context watch --expression 'candidate + 1')
python3 -c 'import json,sys; data=json.load(sys.stdin)["data"]; assert data["result"]=="7" and data["type"]=="Int", data' <<<"$evaluated"

set_result=$("${dap[@]}" request --name "$session" setVariable \
	--json "{\"variablesReference\":$locals_ref,\"name\":\"candidate\",\"value\":\"40\"}")
python3 -c 'import json,sys; data=json.load(sys.stdin)["data"]; assert data["value"]=="40" and data["type"]=="Int", data' <<<"$set_result"
evaluated=$("${dap[@]}" evaluate --name "$session" --frame-id "$current_frame" --context watch --expression 'candidate')
python3 -c 'import json,sys; data=json.load(sys.stdin)["data"]; assert data["result"]=="40", data' <<<"$evaluated"

"${dap[@]}" next --name "$session" >/dev/null
for _ in {1..100}; do
	status=$("${dap[@]}" status --name "$session" 2>/dev/null || true)
	if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status" 2>/dev/null; then
		stack=$("${dap[@]}" stack --name "$session")
		current_frame=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stackFrames"][0]["id"])' <<<"$stack")
		break
	fi
	sleep 0.05
done
evaluated=$("${dap[@]}" evaluate --name "$session" --frame-id "$current_frame" --context watch --expression 'total')
python3 -c 'import json,sys; data=json.load(sys.stdin)["data"]; assert data["result"]=="43", data' <<<"$evaluated"

echo "PASS: dap-cli conditional breakpoints, evaluation, and setVariable preserve frame values"
