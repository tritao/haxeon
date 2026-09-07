#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
cd "$root"
port=${1:-24019}
token=reconnect-test-token
runtime="$root/vendor/hashlink/hl"
target="$root/out/profiler-restart-target.hl"
client="$root/out/profiler-reconnect-test.hl"
export LD_LIBRARY_PATH="$root/out:$root/vendor/hashlink:$root/.tools/hashlink"

"$root/.tools/haxe/haxe" "$root/profiler-restart-target.hxml"
"$root/.tools/haxe/haxe" "$root/profiler-reconnect-test.hxml"
HL_DIAGNOSTICS_TOKEN=$token "$runtime" --diagnostics "$port" "$target" &
first=$!
second=
trap 'kill "$first" "$second" 2>/dev/null || true' EXIT
sleep 0.2
HL_DIAGNOSTICS_TOKEN=$token "$runtime" "$client" "$port" "$token" &
probe=$!
wait "$first"
sleep 0.5
HL_DIAGNOSTICS_TOKEN=$token "$runtime" --diagnostics "$port" "$target" &
second=$!
wait "$probe"
wait "$second"
