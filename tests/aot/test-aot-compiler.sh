#!/usr/bin/env bash
# The CLI and the compiler built ahead of time (build.AotCompiler, docs/design/AOT_BACKEND.md "Shipping the compiler and the CLI"):
# builds the executable and publishes it beside the VM as a release ships it, checks that the haxeon command runs the CLI in it,
# and the CLI's bytecode when its stamp is stale, and that the CLI runs it in each role (one compile, the compile server, the
# language server), then runs integration suites that build through the CLI with it in place. A checkout that had no current one is left
# without one, so the suites after this one keep testing the compiler on the VM.
#
#   tests/aot/test-aot-compiler.sh [jobs]
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
jobs=${1:-4}
hashlink_dir=$("$root_dir/scripts/hashlink-path.sh")
executable=$hashlink_dir/haxeon-aot
stamp=$executable.sources
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-aot-compiler.XXXXXX")

current() {
	local report
	report=$("$root_dir/scripts/haxeon" doctor 2>/dev/null || true)
	grep -q '^ok: CLI and compiler built ahead of time' <<<"$report"
}
had_current=0
if current; then
	had_current=1
fi
cleanup() {
	if [[ -f $work/stamp ]]; then
		cp "$work/stamp" "$stamp"
	fi
	if [[ $had_current == 0 ]]; then
		rm -f "$stamp" "$executable" "$executable.exe"
	fi
	rm -rf "$work"
}
trap cleanup EXIT

if ! "$root_dir/scripts/haxeon" dev aot > "$work/build.log" 2>&1; then
	cat "$work/build.log"
	exit 1
fi
current || { echo "FAIL: haxeon doctor does not report a current compiler built ahead of time" >&2; exit 1; }

# The haxeon command runs the CLI in the executable, or on the VM while the stamp is stale.
version=$("$root_dir/scripts/haxeon" --version)
cp "$stamp" "$work/stamp"
echo stale > "$stamp"
stale_version=$("$root_dir/scripts/haxeon" --version)
mv "$work/stamp" "$stamp"
if [[ $version != haxeon* || $stale_version != "$version" ]]; then
	echo "FAIL: haxeon --version printed \"$version\", and \"$stale_version\" with a stale stamp" >&2
	exit 1
fi

# A project build starts a compile server that is the executable: no worker bytecode is built in the session directory.
mkdir -p "$work/app/src"
printf '%s\n' '{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"outputDir":"build"}' > "$work/app/haxeon.json"
printf '%s\n' 'class Main { public static function main():Int { Sys.println("built ahead of time"); return 3; } }' > "$work/app/src/Main.hx"
export HAXEON_COMPILER_SESSION_DIR=$work/sessions
status=0
HAXEON_COMPILER_IDLE_SECONDS=5 "$root_dir/scripts/haxeon" run --project "$work/app/haxeon.json" > "$work/run.log" 2>&1 || status=$?
if [[ $status != 3 ]] || ! grep -q "built ahead of time" "$work/run.log"; then
	cat "$work/run.log"
	echo "FAIL: the project did not build and run (exit $status)" >&2
	exit 1
fi
if compgen -G "$work/sessions/*.hl" > /dev/null || ! compgen -G "$work/sessions/*.json" > /dev/null; then
	ls -l "$work/sessions"
	echo "FAIL: the compile server was not the compiler built ahead of time" >&2
	exit 1
fi
unset HAXEON_COMPILER_SESSION_DIR

# The language server answers a session in the executable.
python3 - "$executable" "$work/app" <<'PY'
import json, subprocess, sys
executable, project = sys.argv[1], sys.argv[2]
def message(value):
    body = json.dumps(value).encode()
    return b'Content-Length: %d\r\n\r\n' % len(body) + body
root = 'file://' + project
request = message({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'rootUri': root, 'capabilities': {}}})
request += message({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
request += message({'jsonrpc': '2.0', 'id': 2, 'method': 'shutdown'})
request += message({'jsonrpc': '2.0', 'method': 'exit'})
result = subprocess.run([executable, 'lsp'], input=request, capture_output=True, timeout=60)
output = result.stdout.decode()
assert result.returncode == 0 and '"capabilities"' in output and '"id":2' in output, (result.returncode, output[:500],
    result.stderr.decode()[-2000:])
PY

# Suites that compile through the CLI, now with the executable current.
"$root_dir/scripts/haxeon" dev test ci --jobs "$jobs" --only \
	compiler-server,haxeon-script,run-output,process-pipes-integration,native-cmake-library,native-cmake-libraries,cmake-native-package,cxx-project-ffi-cmake
echo "PASS: the compiler built ahead of time compiles, serves and answers the language server, and the CLI's suites pass with it"
