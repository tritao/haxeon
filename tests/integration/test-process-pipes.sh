#!/usr/bin/env bash
# A subprocess gets only its standard streams: the pipes a program opens for it close when it execs. A process the
# subprocess leaves running, with its own streams elsewhere (a daemon, say), then holds none of them, so the program
# reads the subprocess's output to its end as soon as the subprocess exits, not when the descendant does.
set -euo pipefail

case "$(uname -s)" in
	Linux | Darwin) ;;
	*)
		echo "SKIP: Windows processes inherit only handles marked inheritable"
		exit 0
		;;
esac

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hpp-XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/app/src/app"
cat > "$scratch/app/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"app"},"entry":"app.Main","sourceRoots":["src"],"target":"host","outputDir":"build"}
JSON
cat > "$scratch/app/src/app/Main.hx" <<'HAXE'
package app;

class Main {
	static function main():Void {
		var start = Sys.time();
		// The shell exits at once; the sleep it leaves behind keeps running with its streams redirected.
		var process = sys.io.Process.run("sh", ["-c", "sleep 6 > /dev/null 2>&1 < /dev/null & echo started"]);
		var output = process.readStdout();
		process.readStderr();
		process.exitCode();
		process.close();
		Sys.println("read " + StringTools.trim(output) + " after " + Math.round((Sys.time() - start) * 1000) + " ms");
	}
}
HAXE
timeout 300s "$repo_dir/scripts/haxeon" run --project "$scratch/app/haxeon.json" > "$scratch/run.log" 2>&1 || {
	cat "$scratch/run.log" >&2
	exit 1
}
elapsed=$(sed -n 's/^read started after \([0-9]*\) ms$/\1/p' "$scratch/run.log")
if [[ -z "$elapsed" || "$elapsed" -ge 3000 ]]; then
	echo "FAIL: reading a subprocess's output waited ${elapsed:-?} ms for a descendant holding its pipe" >&2
	exit 1
fi
echo "PASS: a subprocess's descendants hold none of its pipes (output read in $elapsed ms)"
