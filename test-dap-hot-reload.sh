#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$repo_dir/vendor/hashlink-debugger"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-hot-reload"
trace_file="$repo_dir/out/hld3-dap-trace.jsonl"
dap=(npx --yes @roblourens/dap-cli@0.3.0)
debug_port=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)

mkdir -p "$repo_dir/out" "$dap_home/config"
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
  "$tools_dir/haxe/haxe" "$repo_dir/dap-hot-reload-probe.hxml"
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

wait_frame() {
  local source=$1 line=$2 stack
  for _ in {1..120}; do
    if stack=$("${dap[@]}" stack --name "$session" 2>/dev/null) &&
      python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0]; assert f.get("source",{}).get("name")==sys.argv[1] and f.get("line")==int(sys.argv[2])' "$source" "$line" <<<"$stack"; then return; fi
    sleep 0.1
  done
  echo "Timed out waiting for $source:$line" >&2
	printf '%s\n' "${stack:-no stack response}" >&2
  return 1
}

assert_local() {
  local expected=$1 scopes ref variables
  scopes=$("${dap[@]}" scopes --name "$session" --frame-id 0)
  ref=$(python3 -c 'import json,sys; print(next(s["variablesReference"] for s in json.load(sys.stdin)["data"]["scopes"] if s["name"]=="Locals"))' <<<"$scopes")
  variables=$("${dap[@]}" variables --name "$session" --variables-reference "$ref")
  python3 -c 'import json,sys; vs=json.load(sys.stdin)["data"]["variables"]; assert any(v["name"]=="result" and sys.argv[1] in v["value"] for v in vs)' "$expected" <<<"$variables"
}

"${dap[@]}" start >/dev/null
launch_json=$(python3 - "$repo_dir" "$debug_port" "$trace_file" <<'PY'
import json,sys
r,port,trace=sys.argv[1:]
print(json.dumps({"type":"hl","request":"launch","name":"HLD3 hot reload","cwd":r+"/out","program":r+"/out/dap-hot-reload-probe.hl","hl":r+"/vendor/hashlink/hl","port":int(port),"classPaths":[r+"/tests/dap",r+"/tests",r+"/src",r+"/.tools/haxe/std"],"env":{"LD_LIBRARY_PATH":r+"/vendor/hashlink","HL_DEBUG_PROTOCOL":"3","HL_DEBUG_TRACE":trace}}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
value=$("${dap[@]}" breakpoints set --name "$session" --source "$repo_dir/tests/dap/Value.hx" --line 4)
python3 -c 'import json,sys; assert json.load(sys.stdin)["data"]["breakpoints"][0]["verified"]' <<<"$value"
wait_frame Value.hx 4
assert_local 43

"${dap[@]}" continue --name "$session" >/dev/null
wait_frame Value.hx 4
assert_local 44
echo "PASS: dap-cli rebound Value.hx:4 from the original to patched function"
