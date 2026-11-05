#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
program=$1
shift
hashlink_dir=$("$root/scripts/hashlink-path.sh")
executable="$hashlink_dir/$program"
case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) executable+=".exe"; export PATH="$root/out:$hashlink_dir:$PATH" ;;
esac
if [[ ! -x "$executable" ]]; then
	echo "Missing checkout-built HashLink program: $executable; run scripts/build-native.sh first" >&2
	exit 1
fi
export LD_LIBRARY_PATH="$root/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="$root/out:$hashlink_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec "$executable" "$@"
