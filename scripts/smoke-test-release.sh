#!/usr/bin/env bash
# Smoke test of a release archive (`haxeon dev package`, docs/DEVELOPMENT.md, Releases), as a user meets it: unpacked into a
# directory of its own outside any checkout, with a home directory of its own so every cache starts cold, and nothing but the
# archive's bin/haxeon. It runs --version, doctor, create (console) + build + run + check of a new project and a script, checks that
# the compiles ran the compiler the archive is meant to run, and runs a program under `run --watch`, edits it and sees
# the running program patched. Where the app template has a runner for this platform it then creates the app, which takes its
# UI package from the release's haxeon registry, builds it through its runner in development and release mode (a C toolchain,
# and on Linux GTK's development files, are needed) and runs each for a few frames, under xvfb-run when there is one, patches
# the app running under `run --watch` (not on Windows), then builds and runs a program that uses the nativekit package
# from the same registry and one that uses filesystem, a NativeKit module's package built on the same NativeKit. Nothing may be
# written into the release's directory:
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
# The platform as the app template names its runners (`AppRunner.hostPlatform`).
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) suffix=.exe windows=1 platform=windows ;;
	Darwin) suffix= windows=0 platform=macos ;;
	*) suffix= windows=0 platform=linux ;;
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
	unset HAXEON_SDK HAXEON_COMPILER_SOURCE HAXEON_COMPILER_SESSION_DIR \
		HAXEON_ARTIFACT_CACHE HAXEON_SCRIPT_CACHE HAXEON_NATIVE_READY HAXEON_COMPILER_SERVER LD_LIBRARY_PATH DYLD_LIBRARY_PATH
	export HOME=$1 USERPROFILE=$1 LOCALAPPDATA=$1/AppData/Local XDG_CACHE_HOME=$1/.cache
	mkdir -p "$HOME" "$LOCALAPPDATA"
}

# Builds, runs and checks a new project in $2 with the release at $1; sets build_seconds to the cold build's time.
project_round() {
	local haxeon=$1/bin/haxeon$suffix project=$2
	mkdir -p "$project"
	(cd "$project" && "$haxeon" create . --template console >/dev/null) || fail "haxeon create"
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

# Waits up to $4 seconds, while the process $1 runs, for file $2 to exist and, unless $3 is empty, for a line of it to match the
# extended regular expression $3. A failure shows the watch's output, $work/live.log.
wait_for() {
	local pid=$1 file=$2 pattern=$3 deadline=$(($(date +%s) + $4))
	until [[ -e $file ]] && { [[ -z $pattern ]] || grep -Eq -- "$pattern" "$file"; }; do
		kill -0 "$pid" 2>/dev/null || { cat "$work/live.log" >&2; fail "the watch exited before $file matched '$pattern'"; }
		(($(date +%s) < deadline)) || { cat "$work/live.log" >&2; fail "$file did not match '$pattern' in $4 s"; }
		sleep 0.2
	done
}

# Stops the process $1 and every process it started, deepest first: a watch's app outlives the CLI that launched it.
stop_tree() {
	local child
	for child in $(pgrep -P "$1" 2>/dev/null || true); do
		stop_tree "$child"
	done
	kill "$1" 2>/dev/null || true
}

# A program `run --watch` patches, as its entry class declares what the live host calls: start, tick and close, and the state
# methods a reload calls. Each tick prints the value $1; the program ends when its directory $2 holds a file `stop`.
live_source() {
	printf '%s\n' 'class Main {' \
		"	static function value():String return \"$1\";" \
		'	public static function start(arguments:String):Void {}' \
		'	public static function tick():Int {' \
		'		Sys.println("live value " + value());' \
		'		Sys.sleep(0.1);' \
		'		return sys.FileSystem.exists("stop") ? 0 : 1;' \
		'	}' \
		'	public static function close():Int return 0;' \
		'	public static function saveState():String return "";' \
		'	public static function restoreState(state:String):Void {}' \
		'	static function main():Void {}' \
		'}' >"$2/src/Main.hx"
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

echo "== haxeon create (console), build, run, check"
project_round "$root" "$work/projects/hello"
aot_seconds=$build_seconds
check_compiler "$root" "$expect_aot"

echo "== console release executable"
console=$work/projects/hello
(cd "$console" && "$haxeon" build --build-mode release) || fail "console release build"
output=$("$console/build/$platform/bin/hello$suffix") || fail "console release executable"
[[ $output == "release smoke: 1,4,9" ]] || fail "console release executable printed: $output"

echo "== haxeon script.hx"
printf 'function main() {\n\tSys.println("script ok " + Sys.args().join(" "));\n}\n' >"$work/projects/hello-script.hx"
output=$(cd "$work/projects" && "$haxeon" hello-script.hx a b) || fail "script run"
[[ $output == "script ok a b" ]] || fail "the script printed: $output"

# The tools that carry the compiler, which a release runs as roles of its compiler's program.
echo "== haxeon lint (a typed rule), haxeon ffi audit, and haxeon dev's refusal"
(cd "$work/projects/hello" && "$haxeon" lint --only unbound-local src/Main.hx) || fail "haxeon lint --only unbound-local"
if command -v clang >/dev/null; then
	printf 'typedef struct point { int x; int y; } point;\nint point_sum(const point *p);\n' >"$work/projects/point.h"
	output=$("$haxeon" ffi audit --target=x86_64-linux-gnu --target=arm64-apple-darwin --profile=portable-abi64 \
		"$work/projects/point.h") ||
		fail "haxeon ffi audit: $output"
	[[ $output == PASS:* ]] || fail "haxeon ffi audit printed: $output"
fi
if output=$("$haxeon" dev tool-build-mode 2>&1); then
	fail "haxeon dev ran in a release: $output"
fi
[[ $output == *"is a release"* ]] || fail "haxeon dev's refusal does not say why: $output"

# The live host the release ships, the compile server's patches, and the edit seen in the running program.
echo "== haxeon run --watch: an edit patches the running program"
live=$work/projects/live
mkdir -p "$live"
(cd "$live" && "$haxeon" create . --template console >/dev/null) || fail "haxeon create of the live program"
live_source one "$live"
(cd "$live" && exec "$haxeon" run --watch) >"$work/live.log" 2>&1 &
watch=$!
wait_for "$watch" "$work/live.log" '^live value one' 300
live_source two "$live"
wait_for "$watch" "$work/live.log" '^live value two' 120
grep -q '"kind":"patch-applied"' "$live/build/host/main.hl.watch-events.jsonl" ||
	{ cat "$work/live.log" >&2; fail "the edit reached the program, but not as a patch"; }
touch "$live/stop"
wait "$watch" || { cat "$work/live.log" >&2; fail "haxeon run --watch exited with status $?"; }

headless=()
if command -v xvfb-run >/dev/null; then
	headless=(xvfb-run -a)
fi
# What --capture=$1 wrote: the frames the app rendered, and on Linux the window's image, which ImageMagick's import takes from
# the X server.
captured() {
	[[ -f $1/frame-metrics.json ]] && grep -Eq '"renderedFrames": *[1-9]' "$1/frame-metrics.json" &&
		{ [[ $platform != linux ]] || [[ -f $1/frame.png ]]; }
}
# `haxeon create` makes an app only for a platform the template has a runner for.
if [[ -d $root/templates/app/$platform ]]; then
	# The app template from the release's templates, its UI package from the release's haxeon registry, built through its
	# runner against the release's SDK with this machine's C toolchain, and run for a few frames.
	echo "== haxeon create (app), build, run, and the same in release mode"
	app=$work/projects/hello-app
	(cd "$work/projects" && "$haxeon" create hello-app >/dev/null) || fail "haxeon create"
	grep -q '^ui = { registry = "haxeon", version = "^' "$app/haxeon.toml" || fail "the app's manifest does not use the UI package from the haxeon registry"
	for target in wasm32 wasm-gc; do
		(cd "$app" && "$haxeon" build --target "$target") || fail "web bundle for $target"
		cmp "$app/build/web/$target/haxeon-host.js" "$root/platforms/web/haxeon-host.js" || fail "staged web loader"
	done
	if [[ -f $root/platforms/android/haxeon-host.aar ]]; then
		(cd "$app" && "$haxeon" build --target android --gradle-inputs build/generated/android/inputs.properties) || fail "Android asset preparation"
		grep -qE '^host=.*haxeon-host\.aar$' "$app/build/generated/android/inputs.properties" ||
			fail "Android runner did not find the release host"
	fi

	(cd "$app" && "$haxeon" build) || fail "haxeon build of the app"
	(cd "$app" && "${headless[@]}" "$haxeon" run -- --frames=3 "--capture=$work/capture") || fail "haxeon run of the app"
	captured "$work/capture" || fail "the app captured no rendered frame"
	(cd "$app" && "$haxeon" install >/dev/null) || fail "haxeon install of the app"
	grep -q '"checksum"' "$app/haxeon.lock" || fail "the release wrote no checksums into the app's haxeon.lock"
	(cd "$app" && "$haxeon" build --build-mode=release) || fail "haxeon build --build-mode=release of the app"
	[[ ! -e $app/build/$platform/app/hello-app.hl ]] || fail "the release build left a module beside the app"
	# Where the runner puts the executable in its directory is the platform's (a bundle on macOS).
	executable=$(find "$app/build/$platform/app" -name "hello-app$suffix" -type f | head -1)
	[[ -n $executable ]] || fail "the release build made no hello-app$suffix under $app/build/$platform/app"
	"${headless[@]}" "$executable" --frames=3 "--capture=$work/capture-release" || fail "the app compiled ahead of time"
	captured "$work/capture-release" || fail "the app compiled ahead of time captured no rendered frame"

	# The live host in the app's runner. The app runs until its window closes, so the test stops it once a patch applied. An
	# edit made before the watch took its first snapshot goes unseen, and one the host sees before it loaded the first module is
	# no patch but the module it loads, so it edits until one applies.
	if [[ $windows == 0 ]]; then
		echo "== haxeon run --watch of the app: an edit patches the running app"
		(cd "$app" && exec "${headless[@]}" "$haxeon" run --watch) >"$work/live.log" 2>&1 &
		watch=$!
		events=$app/build/host/main.hl.watch-events.jsonl
		wait_for "$watch" "$events" '' 300
		for edit in 1 2 3 4 5 6; do
			sed -i.bak -E "s/(You|Edit[0-9]+) clicked/Edit$edit clicked/" "$app/src/Main.hx"
			rm -f "$app/src/Main.hx.bak"
			deadline=$(($(date +%s) + 40))
			until grep -q '"kind":"patch-applied"' "$events" || (($(date +%s) >= deadline)); do
				kill -0 "$watch" 2>/dev/null || { cat "$work/live.log" >&2; fail "the watch of the app exited"; }
				sleep 0.2
			done
			if grep -q '"kind":"patch-applied"' "$events"; then
				break
			fi
		done
		grep -q '"kind":"patch-applied"' "$events" || { cat "$work/live.log" >&2; fail "no edit patched the running app"; }
		stop_tree "$watch"
		wait "$watch" 2>/dev/null || true
	fi

	# A program, not an app, with a native package from the release's registry: its CMake build runs in the shared native
	# cache, which for a release is in the user's cache, with the SDK's CMake scripts and the Ninja on PATH.
	echo "== a program with a native package (nativekit) from the release's registry"
	native=$work/projects/native-program
	mkdir -p "$native"
	(cd "$native" && "$haxeon" create . --template console >/dev/null && "$haxeon" add nativekit >/dev/null) || fail "haxeon add nativekit"
	printf 'function main():Int {\n\tSys.println("native program ok");\n\treturn 0;\n}\n' >"$native/src/Main.hx"
	(cd "$native" && "$haxeon" build) || fail "haxeon build of a program with a native package"
	# The native package's up-to-date check (CMake and Ninja) prints even under --quiet; the program's line is the last.
	output=$(cd "$native" && "$haxeon" run --quiet) || fail "haxeon run of a program with a native package"
	[[ $(tail -n 1 <<<"$output") == "native program ok" ]] || fail "the program with a native package printed: $output"
	[[ -d $HOME/.haxeon/cache/native ]] || fail "the native package was not built in the user's cache"

	# A NativeKit module's package (filesystem), whose CMake project builds the module on the nativekit package's build
	# that the program above left in the cache.
	echo "== a program with a NativeKit module's package (filesystem) from the release's registry"
	module=$work/projects/module-program
	mkdir -p "$module"
	(cd "$module" && "$haxeon" create . --template console >/dev/null && "$haxeon" add filesystem >/dev/null) || fail "haxeon add filesystem"
	printf 'function main():Int {\n\tvar root = new haxeon.filesystem.FileSystemRoot(Sys.getCwd());\n\tSys.println("module program ok " + (root.stat("").get_kind() == nativekit.ffi.NativeKitFilesystemTypes.FileSystemEntryKind.Directory));\n\troot.close();\n\treturn 0;\n}\n' \
		>"$module/src/Main.hx"
	(cd "$module" && "$haxeon" build) || fail "haxeon build of a program with a NativeKit module's package"
	output=$(cd "$module" && "$haxeon" run --quiet) || fail "haxeon run of a program with a NativeKit module's package"
	[[ $(tail -n 1 <<<"$output") == "module program ok true" ]] || fail "the program with filesystem printed: $output"
	nativekit_trees=$(find "$HOME/.haxeon/cache/native" -maxdepth 2 -type d -name 'nativekit-*' | wc -l)
	[[ $nativekit_trees == 1 ]] || fail "NativeKit was built in $nativekit_trees trees of the native cache, not one"
fi
written=$(find "$root" -newer "$root/haxeon-sdk.toml" -type f | head -3)
[[ -z $written ]] || fail "the release wrote into its own directory: $written"

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
