#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
export HAXEON_SDK=${HAXEON_SDK:-$root_dir/out/sdk} # the Haxe test mains start the VM from it
cd "$root_dir"
export LD_LIBRARY_PATH="$root_dir/out:$("$root_dir/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$root_dir/.tools/haxe/haxe" common.hxml -cp tests/compiler --run EnumTypedefConstructorMain
# The test main builds each target with and without inlining and runs every module under node itself.
