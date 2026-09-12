#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
port=${1:-24020}
runtime="$root/.tools/hashlink/hl"
client="$root/.tools/hashlink/hlprof-live"
target="$root/out/profiler-wait-target.hl"
log=$(mktemp /tmp/haxeon-profiler-wait-XXXXXX.log)
capture=$(mktemp /tmp/haxeon-profiler-wait-XXXXXX.hlpc)
pid=
cleanup() {
	if [[ -n "$pid" ]]; then
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
	rm -f "$log" "$capture"
}
trap cleanup EXIT

export LD_LIBRARY_PATH="$root/out:$root/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$root/.tools/haxe/haxe" "$root/tests/hxml/profiler-wait-target.hxml"

"$runtime" --diagnostics "$port" --diagnostics-wait "$target" >"$log" 2>&1 &
pid=$!
sleep 0.2
if ! kill -0 "$pid" 2>/dev/null || rg -q '^started$' "$log"; then
	cat "$log" >&2
	echo "profiler wait did not hold the target before attachment" >&2
	exit 1
fi

"$client" --connect-timeout 5 --rate 100 --duration 1 --output "$capture" "$port" >/dev/null
wait "$pid"
rg -q '^started$' "$log"
echo "PASS: diagnostics-wait holds startup until hlprof-live attaches"
