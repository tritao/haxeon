#!/usr/bin/env bash
# Smoke test of a release archive (`haxeon dev package`, docs/reference/RELEASES.md), as a user meets it: unpacked into a
# directory of its own outside any checkout, with a home directory of its own so every cache starts cold, and nothing but the
# archive's bin/haxeon. It runs --version, doctor, init + build + run + check of a new project and a script, and checks that
# the compiles ran the compiler the archive is meant to run:
#
#   scripts/smoke-test-release.sh ARCHIVE --aot      the CLI and compiler built ahead of time (bin/haxeon-aot)
#   scripts/smoke-test-release.sh ARCHIVE --no-aot   the compiler's bytecode on the VM (bin/haxeon-compiler.hl)
#
# With --aot it then times the same cold build on the VM (the archive without bin/haxeon-aot), which also checks the
# bytecode a release falls back to. The release workflow runs it on each platform's archive.
set -euo pipefail

if [[ $# -ne 2 || ( $2 != --aot && $2 != --no-aot ) ]]; then
	echo "usage: $0 ARCHIVE --aot|--no-aot" >&2
	exit 2
fi
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
expect_aot=$([[ $2 == --aot ]] && echo 1 || echo 0)
python=$(command -v python3 || command -v python)
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) suffix=.exe windows=1 ;;
	*) suffix= windows=0 ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-release-smoke.XXXXXX")
cleanup() {
	# Compiler workers of this test outlive the builds; they idle out, but there is no reason to wait for that.
	if [[ $windows == 0 ]]; then
		pkill -f "$work/" 2>/dev/null || true
	fi
	rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
	echo "release smoke test FAILED: $*" >&2
	exit 1
}

now() { "$python" -c 'import time; print(time.time())'; }
seconds_since() { "$python" -c "import sys, time; print('%.2f' % (time.time() - float(sys.argv[1])))" "$1"; }

# Unpacks the archive into $1 and prints the release root (the archive's one top directory).
unpack() {
	mkdir -p "$1"
	case "$archive" in
		*.tar.gz) tar -xzf "$archive" -C "$1" ;;
		*.zip) "$python" -I -m zipfile -e "$archive" "$1" ;;
		*) fail "unknown archive type: $archive" ;;
	esac
	local entries=("$1"/*)
	[[ ${#entries[@]} == 1 && -f ${entries[0]}/haxeon-sdk.toml ]] || fail "the archive does not hold one release directory"
	! grep -q '^source' "${entries[0]}/haxeon-sdk.toml" || fail "the release's manifest names a checkout"
	# Symbolic links resolved, as the launcher resolves its own path (macOS's temporary directory is one).
	(cd "${entries[0]}" && pwd -P)
}

# A user's environment: no checkout's variables, and a home of its own so caches and compiler sessions start empty.
isolate() {
	unset HAXEON_HOME HAXEON_SDK HAXEON_HASHLINK_DIR HAXEON_COMPILER_SOURCE HAXEON_COMPILER_SESSION_DIR \
		HAXEON_ARTIFACT_CACHE HAXEON_SCRIPT_CACHE HAXEON_NATIVE_READY HAXEON_COMPILER_SERVER LD_LIBRARY_PATH DYLD_LIBRARY_PATH
	export HOME=$1 USERPROFILE=$1 LOCALAPPDATA=$1/AppData/Local XDG_CACHE_HOME=$1/.cache
	mkdir -p "$HOME" "$LOCALAPPDATA"
}

# Builds, runs and checks a new project in $2 with the release at $1; sets build_seconds to the cold build's time.
project_round() {
	local haxeon=$1/bin/haxeon$suffix project=$2
	mkdir -p "$project"
	(cd "$project" && "$haxeon" init >/dev/null) || fail "haxeon init"
	printf 'function main():Int {\n\tSys.println("release smoke: " + [for (i in 1...4) i * i].join(","));\n\treturn 0;\n}\n' \
		>"$project/src/Main.hx"
	local started output
	started=$(now)
	(cd "$project" && "$haxeon" build) || fail "haxeon build"
	build_seconds=$(seconds_since "$started")
	output=$(cd "$project" && "$haxeon" run --quiet) || fail "haxeon run"
	[[ $output == "release smoke: 1,4,9" ]] || fail "haxeon run printed: $output"
	(cd "$project" && "$haxeon" check) || fail "haxeon check"
}

# Whether this run's compiles went through the expected compiler: nothing was built from sources into the session directory
# (a release has no Haxe to build with), and on Linux and macOS the resident worker is that compiler.
check_compiler() {
	local root=$1 aot=$2 sessions
	sessions=$(find "$HOME" -name '*.hl' -path '*compiler*' 2>/dev/null | head -1)
	[[ -z $sessions ]] || fail "the compiler was built from sources: $sessions"
	if [[ $windows == 0 ]]; then
		local worker
		if [[ $aot == 1 ]]; then
			worker=$(pgrep -f "$root/bin/haxeon-aot serve" || true)
		else
			worker=$(pgrep -f "$root/bin/hl $root/bin/haxeon-compiler.hl serve" || true)
		fi
		[[ -n $worker ]] || fail "no compile server of the expected compiler (AOT: $aot) is running"
	fi
}

root=$(unpack "$work/unpacked")
haxeon=$root/bin/haxeon$suffix
isolate "$work/home"

echo "== haxeon --version"
version=$("$haxeon" --version) || fail "haxeon --version"
echo "$version"
commit=$(sed -n 's/^commit = "\(.*\)"/\1/p' "$root/haxeon-sdk.toml" | tr -d '\r')
[[ $version == *"compiler $commit"* ]] || fail "--version does not name the release's commit $commit"

echo "== haxeon doctor"
doctor=$("$haxeon" doctor) || { echo "$doctor"; fail "haxeon doctor"; }
echo "$doctor"
if [[ $expect_aot == 1 ]]; then
	grep -q '^ok: CLI and compiler built ahead of time' <<<"$doctor" || fail "doctor does not report the AOT compiler current"
else
	grep -q '^not built: CLI and compiler built ahead of time' <<<"$doctor" || fail "doctor does not report the AOT compiler not built"
	grep -q '^ok: compiler bytecode' <<<"$doctor" || fail "doctor does not report the compiler bytecode"
fi

echo "== haxeon init, build, run, check"
project_round "$root" "$work/projects/hello"
aot_seconds=$build_seconds
check_compiler "$root" "$expect_aot"

echo "== haxeon script.hx"
printf 'function main() {\n\tSys.println("script ok " + Sys.args().join(" "));\n}\n' >"$work/projects/hello-script.hx"
output=$(cd "$work/projects" && "$haxeon" hello-script.hx a b) || fail "script run"
[[ $output == "script ok a b" ]] || fail "the script printed: $output"

if [[ $expect_aot == 1 ]]; then
	echo "== the same cold build on the VM (without bin/haxeon-aot)"
	jit_root=$(unpack "$work/jit")
	rm -f "$jit_root/bin/haxeon-aot$suffix"
	isolate "$work/jit-home"
	project_round "$jit_root" "$work/jit-projects/hello"
	check_compiler "$jit_root" 0
	echo "Cold build of a new project: ${aot_seconds} s with the compiler built ahead of time, ${build_seconds} s on the VM"
else
	echo "Cold build of a new project: ${aot_seconds} s on the VM"
fi
echo "release smoke test passed: $(basename "$archive")"
