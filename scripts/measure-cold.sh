#!/usr/bin/env bash
# Cold compiler build of an app, measured: wall time, compiler time, compile-count, and the worker's CPU seconds and peak RSS.
#
#   scripts/measure-cold.sh <label> [runs]
#
# Baseline for cold-build comparisons from 2026-11-12 on (so that no scaffold is needed again): haxeon 7b97c092e (origin/main) with the Materia app of
# outer repository commit e9173b977, run as `MEASURE_APP=<outer worktree>/app HAXEON_ROOT=<haxeon worktree at 7b97c092e>`. The outer worktree is a
# detached `git worktree add` of that commit with its submodule directories linked read-only from the shared checkout and `haxeon` linked to the root
# under test (this script relinks it). Compilers older than 2026-11-11's base cannot build this app, and the base (0405feb5) cannot either: compare
# like with like by building the same app with the two compilers being compared. Numbers: docs/TEST_SUITE_COST.md.
#
# Environment:
#   HAXEON_ROOT         the Haxeon checkout whose compiler is measured (default: this checkout)
#   MEASURE_APP         the app project directory, holding haxeon.json (required), or `self-hosting`: the project of
#                       tests/integration/test-compiler-embedding.sh, in which Haxeon compiles the compiler's own sources (about 5200
#                       functions retyped). It is a different workload from the Materia app, so quote percentages only against the same target.
#   MEASURE_OUT         where outputs, logs and samples go (default: out/measure-cold)
#   MEASURE_MAX_LOAD    wait while the 1-minute load average is at or above this (default 6): a loaded machine measures noise
#
# The app finds its compiler through the link `../haxeon` beside it; this script points that link at HAXEON_ROOT for the runs and puts it
# back afterwards, so do not run two measurements against one app at once.
#
# The worker is followed by pid: only a process that appeared after the build started counts, its CPU is read from /proc/<pid>/stat
# (user + system, all threads) and its peak from VmHWM. Only workers of HAXEON_ROOT's own runtime count (a worker of another checkout,
# started by another session, is not ours and is never sampled). Earlier workers are waited out first (a build that finds one alive
# reuses it and is not cold). A run is flagged `polluted=...` in its line when the numbers cannot be trusted: a worker of this root
# was already alive when the build started, a second worker of this root appeared during it, or a worker of another checkout ran
# during it (it competes for memory and CPU, though it is not sampled). Do not quote a polluted run. Each run prints one line; the median of runs is the number to quote. Medians of 3 or more, and the same
# MEASURE_APP for every side of a comparison.
set -u
export LC_ALL=C
label=${1:?usage: measure-cold.sh <label> [runs]}
runs=${2:-3}
root=${HAXEON_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
app=${MEASURE_APP:?set MEASURE_APP to the app project directory, or self-hosting}
out=${MEASURE_OUT:-$root/out/measure-cold}
max_load=${MEASURE_MAX_LOAD:-6}
mkdir -p "$out"
if [ "$app" = self-hosting ]; then
	# The project sits in a directory of its own so that `../haxeon` below is its link to the compiler.
	app=$out/self-hosting/app
	mkdir -p "$app/src"
	cp "$root/tests/fixtures/self-hosting/Main.hx" "$app/src/Main.hx"
	printf '{"version": 1, "package": {"name": "embedding-test"}, "entry": "Main", "sourceRoots": ["src"], "scopeSourceRoots": false, "dependencies": {"haxeon-compiler": {"path": "%s/embed"}}}\n' "$root" >"$app/haxeon.json"
fi
link=$app/../haxeon
previous=$(readlink "$link" || true)
ln -sfn "$root" "$link"
trap '[ -n "$previous" ] && ln -sfn "$previous" "$link"' EXIT
export HAXEON_COMPILER_IDLE_SECONDS=10
unset HL_GC_MARK_THRESHOLD
pattern="[h]ashlink-runtime/hl .*cache/haxeon/compiler/.*json"
ticks=$(getconf CLK_TCK)

# GC time the compiler reports for a build, in ms, in two parts that are never added together because older compilers print only the first:
#   gc-ms           the IR assembly and backend assembly phases (the `allocation phases` line), present in every compiler's log
#   gc-frontend-ms  the stages of each frontend pass that do not overlap (graph, semantic-assembly, signature-inference, typing, ir-generation:
#                   their `Ngc(Tms)` figures); empty when the log has no `frontend pass` lines
# Compare gc-ms across compilers; compare gc-frontend-ms only between logs that both have it.
gc_ms() {
	awk '
		/allocation phases/ {
			for (i = 1; i <= NF; i++)
				if ($i ~ /^(ir-assembly|backend-assembly)-gc-ms=/) { split($i, parts, "="); total += parts[2]; seen = 1 }
		}
		END { if (seen) printf "%.0f", total }
	' "$1"
}

gc_frontend_ms() {
	awk '
		/^frontend pass/ {
			for (i = 1; i <= NF; i++)
				if ($i ~ /^(graph|semantic-assembly|signature-inference|typing|ir-generation)=/ && match($i, /gc\([0-9.]+ms\)/)) {
					value = substr($i, RSTART + 3, RLENGTH - 6); total += value; seen = 1
				}
		}
		END { if (seen) printf "%.0f", total }
	' "$1"
}

# Pids of the workers whose runtime lives under this root (own) or elsewhere (others).
workers() { # own|others
	local pid cmd
	for pid in $(pgrep -f "$pattern"); do
		cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || continue
		case "$cmd" in
		"$root"/*) [ "$1" = own ] && echo "$pid" ;;
		*) [ "$1" = others ] && echo "$pid" ;;
		esac
	done
}

for run in $(seq "$runs"); do
	name=$label-$run
	while [ "$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)" -ge "$max_load" ]; do sleep 30; done
	load=$(cut -d' ' -f1 /proc/loadavg)
	for _ in $(seq 40); do [ -z "$(workers own)" ] && break; sleep 2; done
	flags=""
	[ -n "$(workers own)" ] && flags="$flags own-worker-alive-at-start"
	: >"$out/$name.seen"
	echo 0 >"$out/$name.peak"
	echo 0 >"$out/$name.cpu"
	: >"$out/$name.samples"
	: >"$out/$name.others"
	(
		while true; do
			for pid in $(workers others); do echo "$pid" >>"$out/$name.others"; done
			for pid in $(workers own); do
				[ -r "/proc/$pid/stat" ] || continue
				grep -qx "$pid" "$out/$name.seen" || echo "$pid" >>"$out/$name.seen"
				hwm=$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)
				if [ -n "$hwm" ] && [ "$hwm" -gt "$(cat "$out/$name.peak")" ]; then echo "$hwm" >"$out/$name.peak"; fi
				cpu=$(awk -v t="$ticks" '{printf "%.1f", ($14 + $15) / t}' "/proc/$pid/stat" 2>/dev/null)
				if [ -n "$cpu" ] && awk -v a="$cpu" -v b="$(cat "$out/$name.cpu")" 'BEGIN { exit !(a > b) }'; then
					echo "$cpu" >"$out/$name.cpu"
					echo "$pid $cpu $hwm" >>"$out/$name.samples"
				fi
			done
			sleep 1
		done
	) &
	sampler=$!
	start=$(date +%s.%N)
	(cd "$app" && "$root/scripts/haxeon" build --project haxeon.json --output="$out/$name.hl" --compiler-only --timings >"$out/$name.log" 2>&1)
	status=$?
	end=$(date +%s.%N)
	kill "$sampler" 2>/dev/null
	wait "$sampler" 2>/dev/null
	[ "$(sort -u "$out/$name.seen" | wc -l)" -gt 1 ] && flags="$flags second-worker-of-this-root"
	[ -s "$out/$name.others" ] && flags="$flags other-checkout-worker-ran"
	polluted=""
	[ -n "$flags" ] && polluted=" polluted=${flags# }"
	echo "$name exit=$status load=$load $(grep -o 'compile-count=[0-9]*' "$out/$name.log" | head -1) $(grep '^compiler:' "$out/$name.log") wall=$(echo "$end - $start" | bc | cut -c1-6)s cpu=$(cat "$out/$name.cpu")s peak-rss=$(awk '{printf "%.2f GB", $1 / 1048576}' "$out/$name.peak") gc-ms=$(gc_ms "$out/$name.log") gc-frontend-ms=$(gc_frontend_ms "$out/$name.log")$polluted"
done
