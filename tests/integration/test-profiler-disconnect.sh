#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
runtime="$root/.tools/hashlink/hl"
client="$root/.tools/hashlink/hlprof-live"
target="$root/out/profiler-disconnect-target.hl"
temp_dir=$(mktemp -d /tmp/haxeon-profiler-disconnect-XXXXXX)
runtime_pid=
client_pid=
cleanup() {
	if [[ -n "$client_pid" ]]; then
		kill "$client_pid" 2>/dev/null || true
		wait "$client_pid" 2>/dev/null || true
	fi
	if [[ -n "$runtime_pid" ]]; then
		kill "$runtime_pid" 2>/dev/null || true
		wait "$runtime_pid" 2>/dev/null || true
	fi
	rm -r -- "$temp_dir"
}
trap cleanup EXIT

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
export LD_LIBRARY_PATH="$root/out:$root/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$root/.tools/haxe/haxe" "$root/tests/hxml/profiler-disconnect-target.hxml"

timeout 15 "$client" --connect-timeout 5 --rate 100 --interval 10000 --output "$temp_dir/capture.hlpc" "$port" \
	>"$temp_dir/client.log" 2>&1 &
client_pid=$!
sleep 0.2
"$runtime" --diagnostics "$port" --diagnostics-wait "$target" >"$temp_dir/runtime.log" 2>&1 &
runtime_pid=$!

wait "$runtime_pid"
runtime_pid=
wait "$client_pid"
client_pid=
rg -q '^started$' "$temp_dir/runtime.log"
rg -q '^Profiler target disconnected; finalizing capture$' "$temp_dir/client.log"
"$client" report "$temp_dir/capture.hlpc" >"$temp_dir/report.log" 2>"$temp_dir/report.err"
if [[ -s "$temp_dir/report.err" ]]; then
	cat "$temp_dir/report.err" >&2
	echo "profiler capture was not finalized cleanly" >&2
	exit 1
fi
echo "PASS: profiler retries startup connection and finalizes a complete capture when the target exits"
