#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-exceptions"
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
                "transport": {"kind": "stdio", "command": "node", "args": [adapter + "/adapter.js"], "cwd": adapter},
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

"$tools_dir/haxe/haxe" "$repo_dir/tests/hxml/dap-exception-probe.hxml"
"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" <<'PY'
import json
import sys

root = sys.argv[1]
print(json.dumps({
    "type": "hl", "request": "launch", "name": "HashLink DAP exceptions",
    "cwd": root, "program": root + "/out/dap-exception-probe.hl", "hl": root + "/vendor/hashlink/hl",
    "classPaths": [root + "/tests", root + "/.tools/haxe/std"],
    "env": {"LD_LIBRARY_PATH": root + "/vendor/hashlink", "HL_DEBUG_PROTOCOL": "3"},
}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
"${dap[@]}" request --name "$session" setExceptionBreakpoints --json '{"filters":["all"]}' >/dev/null
breakpoint=$("${dap[@]}" breakpoints set --name "$session" --source "$repo_dir/tests/DapExceptionProbe.hx" --line 18)
python3 -c 'import json,sys; assert json.load(sys.stdin)["data"]["breakpoints"][0]["verified"]' <<<"$breakpoint"

current_thread=
current_frame=
wait_stop() {
	local expected_line=$1 stack status
	current_thread=
	for _ in {1..100}; do
		status=$("${dap[@]}" status --name "$session" 2>/dev/null || true)
		if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status" 2>/dev/null; then
			threads=$("${dap[@]}" threads --name "$session")
			current_thread=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["threads"][0]["id"])' <<<"$threads")
			stack=$("${dap[@]}" stack --name "$session" --thread-id "$current_thread")
			if python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0]; assert f.get("source",{}).get("name")=="DapExceptionProbe.hx" and f.get("line")==int(sys.argv[1])' "$expected_line" <<<"$stack" 2>/dev/null; then
				current_frame=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stackFrames"][0]["id"])' <<<"$stack")
				return
			fi
		fi
		sleep 0.05
	done
	echo "Timed out waiting for DapExceptionProbe.hx:$expected_line" >&2
	printf '%s\n' "${stack:-no stack response}" >&2
	return 1
}

wait_stop 3
caught_info=$("${dap[@]}" request --name "$session" exceptionInfo --json "{\"threadId\":$current_thread}")
python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert d["exceptionId"]=="String" and d["description"]=="caught-probe" and d["breakMode"]=="always", d; assert d["details"]["typeName"]=="String" and "DapExceptionProbe.hx:3" in d["details"]["stackTrace"], d' <<<"$caught_info"
python3 -c 'import json,sys; fs=json.load(sys.stdin)["data"]["stackFrames"]; assert len(fs)>=2 and fs[1].get("source",{}).get("name")=="DapExceptionProbe.hx", fs' <<<"$("${dap[@]}" stack --name "$session" --thread-id "$current_thread")"

"${dap[@]}" continue --name "$session" >/dev/null
wait_stop 18
scopes=$("${dap[@]}" scopes --name "$session" --frame-id "$current_frame")
locals_ref=$(python3 -c 'import json,sys; print(next(s["variablesReference"] for s in json.load(sys.stdin)["data"]["scopes"] if s["name"]=="Locals"))' <<<"$scopes")
locals=$("${dap[@]}" variables --name "$session" --variables-reference "$locals_ref")
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="marker" and v["value"]=="12" for v in vs), vs' <<<"$locals"

"${dap[@]}" continue --name "$session" >/dev/null
wait_stop 12
uncaught_info=$("${dap[@]}" request --name "$session" exceptionInfo --json "{\"threadId\":$current_thread}")
python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert d["exceptionId"]=="String" and d["description"]=="uncaught-probe" and d["details"]["message"]=="uncaught-probe", d; assert "DapExceptionProbe.hx:12" in d["details"]["stackTrace"], d' <<<"$uncaught_info"

echo "PASS: DAP reports caught and uncaught exception values, types, and stacks, and resumes caught exceptions"
