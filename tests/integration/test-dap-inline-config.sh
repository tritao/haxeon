#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-dap-inline.XXXXXX")
project=$work/inline-debug-project
export DAP_CLI_HOME="$work/dap-inline-home"
dap=(npx --yes @roblourens/dap-cli@0.3.0)
session=haxeon-inline-false-probe
cleanup() {
 "${dap[@]}" stop --name "$session" >/dev/null 2>&1 || true
 "${dap[@]}" close "$session" >/dev/null 2>&1 || true
 "${dap[@]}" stop-controller >/dev/null 2>&1 || true
 # Retire only the worker started in this test's private cache, using its authenticated protocol.
 python3 - "$work" <<'PY_CLEANUP'
import json,pathlib,socket,struct,sys,shutil
work=pathlib.Path(sys.argv[1])
for path in (work/'inline-debug-cache/haxeon/compiler').glob('*.json'):
 try:
  state=json.loads(path.read_text())
  payload=json.dumps({'token':state['token'],'shutdown':True}).encode()
  with socket.create_connection(('127.0.0.1',state['port']),timeout=1) as connection:
   connection.sendall(struct.pack('<i',len(payload))+payload)
   connection.recv(4096)
 except (OSError,ValueError,KeyError): pass
shutil.rmtree(work)
PY_CLEANUP
}
trap cleanup EXIT
mkdir -p "$project/src" "$work/dap-inline-home/config"
cat > "$project/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"inline-debug-test"},"entry":"Main","sourceRoots":["src"],"inline":false}
JSON
cat > "$project/src/Main.hx" <<'HX'
class Main {
 public static inline function helper(x:Int):Int { return x + 1; }
 public static function main():Int { Sys.sleep(3.0); return helper(41); }
}
HX
export LD_LIBRARY_PATH="$root/out:$root/.tools/hashlink"
export XDG_CACHE_HOME="$work/inline-debug-cache"
export HAXEON_HOME="$root" HAXEON_COMPILER_SOURCE="$root/src"
export HAXEON_INLINE=1 HAXEON_BOUNDS=0 HAXEON_NATIVE_READY=1
"$root/.tools/haxe/haxe" --cwd "$root" -cp "$root/src" --run tools.HaxeonCli build --project "$project/haxeon.json"
python3 - "$DAP_CLI_HOME/config/adapters.json" "$root/vendor/hashlink-debugger" <<'PY'
import json,sys
path,adapter=sys.argv[1:]
with open(path,'w') as file:json.dump({'adapters':{'hashlink':{'id':'hashlink','label':'HashLink','transport':{'kind':'stdio','command':'node','args':[adapter+'/adapter.js'],'cwd':adapter},'launchDefaults':{'type':'hl','request':'launch'}}},'launchConfigTypeMap':{'hl':'hashlink'}},file)
PY
"${dap[@]}" start >/dev/null
launch=$(python3 - "$root" "$work" "$project" <<'PY'
import json,sys,socket
root,work,project=sys.argv[1:]
s=socket.socket();s.bind(("127.0.0.1",0));port=s.getsockname()[1];s.close()
print(json.dumps({'type':'hl','request':'launch','name':'Inline disabled by manifest','port':port,'cwd':root,'program':project+'/build/host/main.hl','hl':root+'/.tools/hashlink/hl','classPaths':[project+'/src',root+'/stdlib'],'env':{'LD_LIBRARY_PATH':root+'/out:'+root+'/.tools/hashlink','HL_DEBUG_PROTOCOL':'3'}}))
PY
)
"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch" >/dev/null
result=$("${dap[@]}" request --name "$session" setFunctionBreakpoints --json '{"breakpoints":[{"name":"Main.helper"}]}')
python3 -c 'import json,sys; p=json.load(sys.stdin)["data"]["breakpoints"][0];assert p["verified"],p' <<< "$result"
for attempt in {1..30}; do
 status=$("${dap[@]}" status --name "$session")
 if python3 -c 'import json,sys;assert json.load(sys.stdin)["data"]["status"]=="stopped"' <<< "$status" 2>/dev/null; then break; fi
 sleep 0.1
done
stack=$("${dap[@]}" stack --name "$session")
python3 -c 'import json,sys; f=json.load(sys.stdin)["data"]["stackFrames"][0];assert f["name"]=="Main.helper",f' <<< "$stack"
"${dap[@]}" continue --name "$session" >/dev/null
printf '%s\n' 'PASS: manifest inline=false overrides HAXEON_INLINE=1 and stops at an inline helper function breakpoint'
