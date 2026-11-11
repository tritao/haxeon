#!/usr/bin/env bash
# A tool outside the compiler's tree that links the compiler's sources must build with the class paths of common.hxml and its own,
# and nothing else: this is how the editor's project-module builds do it. If a compiler source moves to a directory that common.hxml
# does not list, this fails here instead of in the tool's own repository.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-external-tool.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$root/tests/fixtures/external-tool"
"$root/.tools/haxe/haxe" --cwd "$root" common.hxml -cp "$tools" -main ExternalToolMain -hl "$work/tool.hl"
library=$("$root/scripts/hashlink-path.sh")
LD_LIBRARY_PATH="$library:$root/out${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$library/hl" "$work/tool.hl"

# scripts/compiler-class-paths.sh gives tools outside the tree the same list: exactly common.hxml's -cp entries, as absolute paths.
expected=$(sed -n 's/^-cp //p' "$root/common.hxml" | while IFS= read -r entry; do printf '%s\n' "$root/$entry"; done)
listed=$("$root/scripts/compiler-class-paths.sh")
[[ $listed == "$expected" ]] || { echo "compiler-class-paths.sh differs from common.hxml: got [$listed], expected [$expected]" >&2; exit 1; }
arguments=$("$root/scripts/compiler-class-paths.sh" --cp-args)
[[ $arguments == "$(printf '%s\n' "$expected" | sed 's/^/-cp\n/')" ]] || { echo "compiler-class-paths.sh --cp-args is not -cp and the path, per class path" >&2; exit 1; }
# Without common.hxml it fails and says why: a checkout older than the tools that ask is not guessed at.
copy="$work/checkout"
mkdir -p "$copy/scripts"
cp "$root/scripts/compiler-class-paths.sh" "$copy/scripts/"
if message=$("$copy/scripts/compiler-class-paths.sh" 2>&1); then
	echo "compiler-class-paths.sh succeeded without a common.hxml" >&2
	exit 1
fi
[[ $message == *"has no common.hxml"* ]] || { echo "compiler-class-paths.sh failed without saying why: $message" >&2; exit 1; }
echo "PASS: compiler-class-paths.sh lists common.hxml's class paths and refuses a checkout without it"
