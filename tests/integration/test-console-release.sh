#!/usr/bin/env bash
# A console program's release build (`ConsoleProgram`): an executable in build/<os>/bin/ with the shared libraries of its
# native packages beside it, which runs started directly and after the directory is copied elsewhere; a build with no
# change leaves it alone, and the libraries of a dropped package are removed.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
haxeon=$root/scripts/haxeon
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-console-release.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) os=windows suffix=.exe ;;
	Darwin) os=macos suffix= ;;
	*) os=linux suffix= ;;
esac

# Runs the executable $1 with no library path from the environment, from directory $2.
run_alone() {
	(cd "$2" && env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH "$1" "${@:3}")
}

export HAXEON_COMPILER_SERVER=0
cd "$work"
"$haxeon" create tool --template console
cd tool
bin=build/$os/bin
executable=$bin/tool$suffix

"$haxeon" build --build-mode release --plan > "$work/plan.log"
for step in program-configure program-build program-ship; do
	grep -F "$step:" "$work/plan.log"
done
"$haxeon" build --build-mode release
[[ $(run_alone "$work/tool/$executable" /) == "Hello from tool" ]]
[[ ! -e build/host/main.hl ]]

stamp=$(cksum < "$executable")
"$haxeon" build --build-mode release
[[ $(cksum < "$executable") == "$stamp" ]] || { echo "an unchanged build rebuilt the executable" >&2; exit 1; }

cat > src/Main.hx <<'HAXE'
function main():Int {
	Sys.println(Sys.args().join("|"));
	return 0;
}
HAXE
[[ $("$haxeon" run --build-mode release --quiet -- "two words" three) == "two words|three" ]]
[[ $(run_alone "$work/tool/$executable" / changed) == "changed" ]]

if "$haxeon" run --build-mode release --watch > "$work/watch.log" 2>&1; then
	echo "release watch unexpectedly succeeded" >&2
	exit 1
fi
grep -F 'cannot be watched or patched live' "$work/watch.log"

# A program that uses a package with native code ships that package's libraries beside it.
cat >> haxeon.toml <<TOML

[dependencies]
haxeon-filesystem = { path = "$root/packages/filesystem" }
TOML
cat > src/Main.hx <<'HAXE'
import haxeon.filesystem.FileSystemRoot;

function main():Int {
	var root = new FileSystemRoot(Sys.getCwd());
	Sys.println("found " + (root.stat("haxeon.toml") != null));
	return 0;
}
HAXE
"$haxeon" build --build-mode release
ls "$bin" | grep -E 'nativekit_filesystem' > /dev/null || { echo "the filesystem package's library was not shipped" >&2; ls -A "$bin" >&2; exit 1; }
[[ $(run_alone "$work/tool/$executable" "$work/tool") == "found true" ]]
cp -R "$bin" "$work/shipped"
[[ $(run_alone "$work/shipped/tool$suffix" "$work/tool") == "found true" ]]

# Without the package, the next build removes what it shipped.
sed -i.bak '/^\[dependencies\]/,$d' haxeon.toml
cat > src/Main.hx <<'HAXE'
function main():Int {
	Sys.println("plain");
	return 0;
}
HAXE
"$haxeon" build --build-mode release
if ls "$bin" | grep -E 'nativekit' > /dev/null; then
	echo "libraries of a dropped package stayed in $bin" >&2
	ls -A "$bin" >&2
	exit 1
fi
[[ $(run_alone "$work/tool/$executable" /) == "plain" ]]

echo 'PASS: a console release runs on its own with its native libraries, and an unchanged build leaves it alone'
