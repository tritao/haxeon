# Shared setup for scripts that run this checkout's tools. Source it; it defines functions and two variables and runs nothing:
#
#   source "$root_dir/scripts/lib/env.sh"
#   haxeon_require_haxe                 # exit 1, saying how to fix it, unless the pinned Haxe is installed
#   haxeon_require_hashlink             # exit 1 unless the checkout-built HashLink is
#   haxeon_export_library_path [DIR...] # put out/, the HashLink directory and DIRs on the library path
#
# haxeon_root is the repository root and haxeon_haxe the pinned Haxe, wherever the sourcing script lives.

haxeon_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
haxeon_haxe="$haxeon_root/.tools/haxe/haxe"

haxeon_require_haxe() {
	if [[ ! -x $haxeon_haxe ]]; then
		echo "missing pinned Haxe: $haxeon_haxe; run scripts/bootstrap-tools.sh first" >&2
		exit 1
	fi
}

haxeon_require_hashlink() {
	local directory
	directory=$("$haxeon_root/scripts/hashlink-path.sh") || exit 1
	if [[ ! -x $directory/hl ]]; then
		echo "missing checkout-built HashLink: $directory/hl; run scripts/build-native.sh first" >&2
		exit 1
	fi
}

# Prepends to every variable a platform reads, so a script works unchanged on Linux (LD_LIBRARY_PATH), macOS
# (DYLD_LIBRARY_PATH) and Windows shells (PATH).
haxeon_export_library_path() {
	local directories directory
	directories="$haxeon_root/out:$("$haxeon_root/scripts/hashlink-path.sh")" || exit 1
	for directory in "$@"; do
		directories+=":$directory"
	done
	export LD_LIBRARY_PATH="$directories${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	export DYLD_LIBRARY_PATH="$directories${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) export PATH="$directories:$PATH" ;;
	esac
}
