#!/usr/bin/env bash
# The native build publishes the VM by rename (cmake/haxeon-replace.cmake): a VM that is running when a new one is published
# keeps running on its own file and finishes normally, and the next start runs the new one.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/lib/env.sh"
haxeon_require_hashlink
vm=$("$root/scripts/hashlink-path.sh")/hl
[[ -x $vm ]] || vm=$vm.exe
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-replace.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/src"

cat >"$work/src/Main.hx" <<'HX'
function main():Int {
	Sys.sleep(2);
	return 42;
}
HX
compiler=$("$root/scripts/haxeon" dev tool-path compiler.tools.HaxeonCompiler)
"$vm" "$compiler" --output="$work/sleep.hl" --entry=Main --root="$work/src" --root="$root/stdlib" "$work/src/Main.hx" >/dev/null

published=$work/bin/$(basename "$vm")
cp "$vm" "$published"
# A different file to publish: the same VM with a byte appended, which it ignores.
cp "$vm" "$work/next"
printf '\n' >>"$work/next"

"$published" "$work/sleep.hl" &
running=$!
sleep 0.5
cmake -DFROM="$work/next" -DTO="$published" -P "$root/cmake/haxeon-replace.cmake"
status=0
wait "$running" || status=$?
if [[ $status != 42 ]]; then
	echo "FAIL: the VM running when a new one was published exited with $status, not 42" >&2
	exit 1
fi
if ! cmp -s "$work/next" "$published"; then
	echo "FAIL: the published VM is not the new file" >&2
	exit 1
fi
if ls "$work/bin" | grep -q '\.new-'; then
	echo "FAIL: a staged copy was left beside the published VM" >&2
	exit 1
fi
status=0
"$published" "$work/sleep.hl" || status=$?
if [[ $status != 42 ]]; then
	echo "FAIL: the newly published VM exited with $status, not 42" >&2
	exit 1
fi
echo "PASS: a running VM keeps its file while a new one is published, and the next start runs the new one"
