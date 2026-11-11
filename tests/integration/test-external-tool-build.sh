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
