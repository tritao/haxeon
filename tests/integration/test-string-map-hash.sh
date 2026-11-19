#!/usr/bin/env bash
# A String type with an unnamed third field keeps the hash string maps compute; other String types are hashed on every lookup.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$("$root/scripts/hashlink-path.sh")}
source "$root/scripts/lib/env.sh"
PATH="$library:$PATH" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$(haxeon_native_test string_map_hash)"
