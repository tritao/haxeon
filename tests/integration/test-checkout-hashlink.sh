#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
if [[ $(uname -s) != Linux ]]; then
	echo 'SKIP: bootstrap mtime check requires Linux'
	exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-checkout-hl.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
# The checkout builds its VM under out/cmake; a build must leave the shared toolchain directory as it was, including absent
# (a fresh checkout has none).
snapshot() {
	if [[ -e "$root/.tools/hashlink" ]]; then
		find -L "$root/.tools/hashlink" -type f -printf '%p %T@ %s\n' | LC_ALL=C sort
	else
		echo 'absent'
	fi
}
snapshot > "$work/before"
df -h /
"$root/scripts/build-native.sh" > "$work/build.log" 2>&1
snapshot > "$work/after"
cmp "$work/before" "$work/after"
mkdir -p "$work/project/src"
cp "$root/tests/programs/defer-exception-stack.hx" "$work/project/src/Main.hx"
printf '%s\n' '{"version":1,"package":{"name":"checkout-vm-test"},"entry":"Main","sourceRoots":["src"],"target":"host","outputDir":"build"}' > "$work/project/haxeon.json"
set +e
"$root/scripts/haxeon" run --project "$work/project/haxeon.json" > "$work/cli.log" 2>&1
status=$?
set -e
if [[ $status != 42 ]]; then
	cat "$work/cli.log" >&2
	echo "FAIL: cleanup fixture exited $status, expected 42" >&2
	exit 1
fi
echo 'PASS: release build preserves bootstrap toolchain and CLI runs cleanup fixture'
