#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe=${HAXEON_REAL_HAXE:-"$root_dir/.tools/haxe/haxe"}
hl="$root_dir/.tools/hashlink/hl"
cli=${HAXEON_TEST_CLI_HL:-"$root_dir/out/test-tools/haxeon-cli.hl"}
original=("$@")

# Integration scripts use the standard Haxe --run form. Dispatch that CLI
# entrypoint to the once-compiled HashLink binary; preserve other Haxe calls.
if [[ $# -ge 6 && $1 == --cwd && $3 == -cp && $5 == --run && $6 == tools.HaxeonCli ]]; then
	cwd=$2
	shift 6
	cd "$cwd"
	case $(uname -s) in
		Darwin)
			export DYLD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
			;;
		*)
			export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
			;;
	esac
	exec "$hl" "$cli" "$@"
fi

exec "$haxe" "${original[@]}"
