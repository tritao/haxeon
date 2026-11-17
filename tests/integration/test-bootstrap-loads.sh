#!/usr/bin/env bash
# The checked-in compiler (bootstrap/compiler.hl) is what `haxeon build --self-hosted` runs. Whether it is still the compiler's fixed
# point is not checked here (that holds only until the next compiler change; `haxeon dev bootstrap --self` checks it). That it loads
# on this checkout's VM and compiles a program is: a runtime native the VM no longer has makes it fail at load, and nothing else
# would notice until someone builds with it. Refresh it with `scripts/haxeon dev bootstrap`.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if ! "$repo_dir/scripts/hashlink-launch.sh" hl "$repo_dir/bootstrap/compiler.hl" --entry=add --root="$repo_dir/tests/programs" \
	--output="$work/add.hl" "$repo_dir/tests/programs/add.hx" > "$work/compile.log" 2>&1; then
	cat "$work/compile.log" >&2
	echo "FAIL: bootstrap/compiler.hl does not load or compile on this VM; refresh it with scripts/haxeon dev bootstrap" >&2
	exit 1
fi
status=0
"$repo_dir/scripts/hashlink-launch.sh" hl "$work/add.hl" > "$work/run.log" 2>&1 || status=$?
if [[ "$status" != 42 ]]; then
	cat "$work/run.log" >&2
	echo "FAIL: the program bootstrap/compiler.hl compiled exited with $status, not 42" >&2
	exit 1
fi
echo "PASS: bootstrap/compiler.hl loads on this VM and compiles a program that runs"
