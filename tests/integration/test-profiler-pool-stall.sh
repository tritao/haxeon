#!/usr/bin/env bash
# A program that keeps the profiler's pool empty while it allocates still finishes: a thread stalled for a chunk blocks
# for the GC, so a collection does not wait for it while the consumer that would free the chunk waits for the collection.
# Before that, four threads making short calls and allocating with a 1 MiB pool hung in about two runs of five.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
runtime="$repo_dir/.tools/hashlink/hl"
client="$repo_dir/.tools/hashlink/hlprof-live"
port=${1:-24030}
runs=${PROFILER_POOL_STALL_RUNS:-5}
scratch=$(mktemp -d /tmp/haxeon-profiler-pool-stall-XXXXXX)
pid=
client_pid=
cleanup() {
	for p in "$pid" "$client_pid"; do
		if [[ -n "$p" ]]; then
			kill -9 "$p" 2>/dev/null || true
			wait "$p" 2>/dev/null || true
		fi
	done
	rm -rf "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/src"
cat > "$scratch/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"profiler-pool-stall"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$scratch/src/Main.hx" <<'HAXE'
class Main {
	static function tiny(i:Int):Int {
		var x = 0;
		for (j in 0...3)
			x += (i + j) % 7;
		return x;
	}

	static function work(seconds:Float):Int {
		var kept:Array<Array<Int>> = [];
		var total = 0;
		var start = Sys.time();
		while (Sys.time() - start < seconds) {
			for (i in 0...10)
				total += tiny(i);
			var block = [for (i in 0...16) i];
			if (kept.length < 256) kept.push(block) else kept[total & 255] = block;
		}
		return total;
	}

	static function main():Void {
		var seconds = Std.parseFloat(Sys.args()[0]);
		var done = new sys.thread.Lock();
		for (t in 0...4)
			sys.thread.Thread.create(function() {
				work(seconds);
				done.release();
			});
		for (t in 0...4)
			done.wait();
		Sys.println("pool stall test finished");
	}
}
HAXE

# Builds the instrumented flavor; a run of no work records next to nothing.
timeout 300s "$repo_dir/scripts/haxeon" run --project "$scratch/haxeon.json" --profile=instrument \
	--profile-output "$scratch/build-capture/profile.hlpc" -- 0 > "$scratch/build.log" 2>&1 || {
	cat "$scratch/build.log" >&2
	exit 1
}
bytecode="$scratch/build-instrument/host/main.hl"
test -s "$bytecode"

export LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
for run in $(seq 1 "$runs"); do
	"$runtime" --diagnostics "$port" --diagnostics-wait "$bytecode" 2 > "$scratch/run.log" 2>&1 &
	pid=$!
	sleep 0.2
	"$client" --connect-timeout 5 --sources instrument --pool 1 --min-call-us 0 --duration 30 \
		--output "$scratch/capture.hlpc" "$port" > "$scratch/client.log" 2>&1 &
	client_pid=$!
	for _ in $(seq 1 200); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		echo "FAIL: run $run of $runs did not finish with the pool kept empty" >&2
		tail -2 "$scratch/client.log" >&2
		exit 1
	fi
	wait "$pid"
	pid=
	kill "$client_pid" 2>/dev/null || true
	wait "$client_pid" 2>/dev/null || true
	client_pid=
	grep -q "pool stall test finished" "$scratch/run.log"
	grep -Eq "stalls [1-9]" "$scratch/client.log" || {
		echo "FAIL: run $run never emptied the pool, so it tested nothing" >&2
		tail -2 "$scratch/client.log" >&2
		exit 1
	}
	rm -f "$scratch/capture.hlpc"
done
echo "PASS: $runs runs that keep the profiler's pool empty while allocating all finish"
