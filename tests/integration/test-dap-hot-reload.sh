#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-hot-reload"
trace_file="$repo_dir/out/hld3-dap-trace.jsonl"
source_dir="$repo_dir/out/dap-hot-reload-source"
dap=(npx --yes @roblourens/dap-cli@0.3.0)
debug_port=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)

mkdir -p "$repo_dir/out" "$dap_home/config"
mkdir -p "$source_dir"
python3 - "$repo_dir/tests/dap/Value.hx" "$source_dir/Value.patched.hx" "$source_dir/Value.patched-again.hx" "$source_dir/Value.hx" <<'PY'
import sys
source, patched, patched_again, initial = sys.argv[1:]
text = open(source, encoding="utf-8").read().rstrip("\n")
open(patched, "w", encoding="utf-8").write(text)
open(patched_again, "w", encoding="utf-8").write(text.replace("var result = 43;", "var result = 44;"))
open(initial, "w", encoding="utf-8").write(text.replace("    ", "  ").replace("var result = 43;", "var result = 42;"))
PY
: > "$trace_file"
make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl
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
if [[ "${SKIP_DAP_BUILD:-0}" != 1 ]]; then
  "$tools_dir/haxe/haxe" "$repo_dir/tests/hxml/dap-hot-reload-probe.hxml"
fi

python3 - "$dap_home/config/adapters.json" "$adapter_dir" <<'PY'
import json, sys
target, adapter = sys.argv[1:]
with open(target, "w", encoding="utf-8") as output:
    json.dump({"adapters":{"hashlink":{"id":"hashlink","label":"HashLink Debug Adapter","transport":{"kind":"stdio","command":"node","args":[adapter+"/adapter.js"],"cwd":adapter},"launchDefaults":{"type":"hl","request":"launch"}}},"launchConfigTypeMap":{"hl":"hashlink"}}, output)
PY
export DAP_CLI_HOME="$dap_home"
export HL_DEBUG_TRACE="$trace_file"
cleanup() {
	local status=$?
  "${dap[@]}" stop --name "$session" >/dev/null 2>&1 || true
  "${dap[@]}" close "$session" >/dev/null 2>&1 || true
  "${dap[@]}" stop-controller >/dev/null 2>&1 || true
	if [[ $status -ne 0 && -s "$trace_file" ]]; then
		echo "HLD3/DAP diagnostic trace:" >&2
		sed -n '1,240p' "$trace_file" >&2
	fi
}
trap cleanup EXIT
current_frame=
current_stack=

wait_frame() {
	local source=$1 line=$2 stack status
  for _ in {1..120}; do
	if status=$("${dap[@]}" status --name "$session" 2>/dev/null) &&
	  python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data",{}).get("status")=="stopped" else 1)' <<<"$status"; then
		stack=$("${dap[@]}" stack --name "$session")
		if ! python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0]; assert f.get("source",{}).get("name")==sys.argv[1] and f.get("line")==int(sys.argv[2])' "$source" "$line" <<<"$stack"; then
			printf '%s\n' "$stack" >&2
			return 1
		fi
		current_frame=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stackFrames"][0]["id"])' <<<"$stack")
		current_stack=$stack
		return
	fi
    sleep 0.1
  done
  echo "Timed out waiting for $source:$line" >&2
	printf '%s\n' "${stack:-no stack response}" >&2
  return 1
}

read_locals() {
	local scopes ref
	scopes=$("${dap[@]}" scopes --name "$session" --frame-id "$current_frame")
	ref=$(python3 -c 'import json,sys; print(next(s["variablesReference"] for s in json.load(sys.stdin)["data"]["scopes"] if s["name"]=="Locals"))' <<<"$scopes")
	"${dap[@]}" variables --name "$session" --variables-reference "$ref"
}

"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" "$debug_port" "$trace_file" <<'PY'
import json,sys
r,port,trace=sys.argv[1:]
print(json.dumps({"type":"hl","request":"launch","name":"HLD3 hot reload","cwd":r+"/out","program":r+"/out/dap-hot-reload-probe.hl","hl":r+"/vendor/hashlink/hl","port":int(port),"classPaths":[r+"/out/dap-hot-reload-source",r+"/tests",r+"/src",r+"/.tools/haxe/std"],"env":{"LD_LIBRARY_PATH":r+"/vendor/hashlink","HL_DEBUG_PROTOCOL":"3","HL_DEBUG_TRACE":trace}}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
value=$("${dap[@]}" breakpoints set --name "$session" --source "$source_dir/Value.hx" --line 6)
python3 -c 'import json,sys; points=json.load(sys.stdin)["data"]["breakpoints"]; assert len(points)==1 and points[0]["verified"]' <<<"$value"
wait_frame Value.hx 6
initial_modules=$("${dap[@]}" request --name "$session" modules --json '{}')
module_id=$(python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert d["totalModules"]==len(d["modules"])>=1, d; matches=[m for m in d["modules"] if m["sourceSnapshots"]>=1]; assert len(matches)==1, d; m=matches[0]; assert m["version"]=="1" and m["revision"]==1, m; assert m["activeRegions"]==0 and m["retiredRegions"]==0, m; print(m["id"])' <<<"$initial_modules")
initial_events=$("${dap[@]}" events --name "$session" --include module)
event_cursor=$(python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; matches=[e for e in d["events"] if e.get("body",{}).get("reason")=="new" and str(e.get("body",{}).get("module",{}).get("id"))==sys.argv[1]]; assert len(matches)==1, d; assert matches[0]["body"]["module"]["version"]=="1", matches[0]; print(d["cursor"])' "$module_id" <<<"$initial_events")
first_module=$("${dap[@]}" request --name "$session" modules --json '{"startModule":0,"moduleCount":1}')
python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert d["totalModules"]>=1 and len(d["modules"])==1, d' <<<"$first_module"
locals=$(read_locals)
python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="result" and v.get("value")=="43" for v in vs), vs; assert any(v["name"]=="scoped" and v.get("value")=="142" for v in vs), vs' <<<"$locals"

cp "$source_dir/Value.patched.hx" "$source_dir/Value.hx"
"${dap[@]}" breakpoints clear --name "$session" --source "$source_dir/Value.hx" >/dev/null
"${dap[@]}" continue --name "$session" >/dev/null
patched_events=
for _ in {1..120}; do
	patched_events=$("${dap[@]}" events --name "$session" --after-cursor "$event_cursor" --include module)
	if python3 -c 'import json,sys; events=json.load(sys.stdin)["data"]["events"]; raise SystemExit(0 if any(e.get("body",{}).get("reason")=="changed" and str(e.get("body",{}).get("module",{}).get("id"))==sys.argv[1] and e["body"]["module"]["version"]=="2" for e in events) else 1)' "$module_id" <<<"$patched_events"; then break; fi
	sleep 0.05
done
event_cursor=$(python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; matches=[e for e in d["events"] if e.get("body",{}).get("reason")=="changed" and str(e.get("body",{}).get("module",{}).get("id"))==sys.argv[1]]; assert len(matches)==1, d; assert matches[0]["body"]["module"]["version"]=="2", matches[0]; print(d["cursor"])' "$module_id" <<<"$patched_events")
patched_modules=$("${dap[@]}" request --name "$session" modules --json '{}')
python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; matches=[m for m in d["modules"] if str(m["id"])==sys.argv[1]]; assert len(matches)==1, d; m=matches[0]; assert m["version"]=="2" and m["revision"]==2, m; assert m["activeRegions"]>=1 and m["retiredRegions"]==0, m; assert m["sourceSnapshots"]>=1, m' "$module_id" <<<"$patched_modules"

cp "$source_dir/Value.patched-again.hx" "$source_dir/Value.hx"
third_events=
for _ in {1..120}; do
	third_events=$("${dap[@]}" events --name "$session" --after-cursor "$event_cursor" --include module)
	if python3 -c 'import json,sys; events=json.load(sys.stdin)["data"]["events"]; raise SystemExit(0 if any(e.get("body",{}).get("reason")=="changed" and str(e.get("body",{}).get("module",{}).get("id"))==sys.argv[1] and e["body"]["module"]["version"]=="3" for e in events) else 1)' "$module_id" <<<"$third_events"; then break; fi
	sleep 0.05
done
third_modules=$("${dap[@]}" request --name "$session" modules --json '{}')
python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; matches=[m for m in d["modules"] if str(m["id"])==sys.argv[1]]; assert len(matches)==1, d; m=matches[0]; assert m["version"]=="3" and m["revision"]==3, m; assert m["activeRegions"]>=1 and m["retiredRegions"]>=0, m; assert m["sourceSnapshots"]>=1, m' "$module_id" <<<"$third_modules"
event_cursor=$(python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; matches=[e for e in d["events"] if e.get("body",{}).get("reason")=="changed" and str(e.get("body",{}).get("module",{}).get("id"))==sys.argv[1]]; assert len(matches)==1, d; m=matches[0]["body"]["module"]; assert m["version"]=="3" and m["revision"]==3 and m["retiredRegions"]>=0, m; print(d["cursor"])' "$module_id" <<<"$third_events")
removed_events=
for _ in {1..120}; do
	removed_events=$("${dap[@]}" events --name "$session" --after-cursor "$event_cursor" --include module)
	if python3 -c 'import json,sys; events=json.load(sys.stdin)["data"]["events"]; raise SystemExit(0 if any(e.get("body",{}).get("reason")=="removed" and str(e.get("body",{}).get("module",{}).get("id"))==sys.argv[1] for e in events) else 1)' "$module_id" <<<"$removed_events"; then break; fi
	sleep 0.05
done
python3 -c 'import json,sys; events=json.load(sys.stdin)["data"]["events"]; matches=[e for e in events if e.get("body",{}).get("reason")=="removed" and str(e.get("body",{}).get("module",{}).get("id"))==sys.argv[1]]; assert len(matches)==1, events' "$module_id" <<<"$removed_events"
remaining_modules=$("${dap[@]}" request --name "$session" modules --json '{}')
python3 -c 'import json,sys; modules=json.load(sys.stdin)["data"]["modules"]; assert all(str(m["id"])!=sys.argv[1] for m in modules), modules' "$module_id" <<<"$remaining_modules"
echo "PASS: dap-cli recorded the complete module lifecycle through hot reload and removal"
