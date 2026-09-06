#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")" && pwd)"
tools_dir="$repo_dir/.tools"
adapter_dir="$tools_dir/hashlink-adapter-package/unpacked/extension"
dap_home="$tools_dir/dap-cli-home"
session="hl-dap-smoke"
dap=(npx --yes @roblourens/dap-cli@0.3.0)

mkdir -p "$repo_dir/out" "$tools_dir/hashlink-adapter-package" "$dap_home/config"

if [[ ! -f "$adapter_dir/adapter.js" ]]; then
  package="$tools_dir/hashlink-adapter-package/haxe-hl-2.0.0.vsix.gz"
  archive="$tools_dir/hashlink-adapter-package/haxe-hl-2.0.0.vsix"
  curl -fL \
    "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/HaxeFoundation/vsextensions/haxe-hl/2.0.0/vspackage" \
    -o "$package"
  echo "13be8457103b31021c7a1fdb1ac1d197d63433d0a46a0557554507362c901a7b  $package" | sha256sum --check
  gzip -dc "$package" > "$archive"
  unzip -q -o "$archive" -d "$tools_dir/hashlink-adapter-package/unpacked"
fi

python3 - "$dap_home/config/adapters.json" "$adapter_dir" "$repo_dir" <<'PY'
import json
import sys

target, adapter, repository = sys.argv[1:]
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
                "attachDefaults": {"type": "hl", "request": "attach"},
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

"$tools_dir/haxe/haxe" "$repo_dir/dap-cli-probe.hxml"
"${dap[@]}" start >/dev/null

launch_json=$(python3 - "$repo_dir" <<'PY'
import json
import sys

root = sys.argv[1]
print(json.dumps({
    "type": "hl",
    "request": "launch",
    "name": "HashLink DAP smoke test",
    "cwd": root,
    "program": root + "/out/dap-cli-probe.hl",
    "hl": root + "/vendor/hashlink/hl",
    "classPaths": [root + "/tests", root + "/.tools/haxe/std"],
    "env": {"LD_LIBRARY_PATH": root + "/vendor/hashlink"},
}))
PY
)

"${dap[@]}" launch --adapter hashlink --name "$session" --json "$launch_json" >/dev/null
breakpoints=$("${dap[@]}" breakpoints set --name "$session" --source "$repo_dir/tests/DapCliProbe.hx" --line 4)
python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["ok"] and data["data"]["breakpoints"][0]["verified"]' <<<"$breakpoints"

stopped=false
for _ in {1..20}; do
  status=$("${dap[@]}" status --name "$session")
  if python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("data", {}).get("status") == "stopped" else 1)' <<<"$status"; then
    stopped=true
    break
  fi
  sleep 0.1
done
if [[ "$stopped" != true ]]; then
  echo "DAP session did not stop at the source breakpoint" >&2
  exit 1
fi

stack=$("${dap[@]}" stack --name "$session")
python3 -c 'import json,sys; frame=json.load(sys.stdin)["data"]["stackFrames"][0]; assert frame["name"] == "DapCliProbe.main" and frame["line"] == 4 and frame["source"]["name"] == "DapCliProbe.hx"' <<<"$stack"

scopes=$("${dap[@]}" scopes --name "$session" --frame-id 0)
locals_ref=$(python3 -c 'import json,sys; scopes=json.load(sys.stdin)["data"]["scopes"]; print(next(scope["variablesReference"] for scope in scopes if scope["name"] == "Locals"))' <<<"$scopes")
variables=$("${dap[@]}" variables --name "$session" --variables-reference "$locals_ref")
python3 -c 'import json,sys; variables=json.load(sys.stdin)["data"]["variables"]; assert any(value["name"] == "index" for value in variables)' <<<"$variables"

echo "PASS: dap-cli hit DapCliProbe.hx:4 and resolved its stack frame and locals"
