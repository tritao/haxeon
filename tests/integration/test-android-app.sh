#!/usr/bin/env bash
set -euo pipefail

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ANDROID_HOME=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"$root/.tools/android-sdk"}}
adb="$ANDROID_HOME/platform-tools/adb"
[[ -x "$adb" ]] || fail "adb is missing at $adb. Set ANDROID_HOME to the Android SDK."

devices=$("$adb" devices) || fail "Could not list Android devices."
device=${ANDROID_SERIAL:-}
if [[ -z "$device" ]]; then
	device=$(awk '$2 == "device" {print $1}' <<< "$devices")
	[[ "$device" != *$'\n'* ]] || fail "Multiple Android devices are online. Set ANDROID_SERIAL."
fi
[[ -n "$device" ]] || fail "No online Android device. Connect one or start an emulator first."
[[ $("$adb" -s "$device" get-state) == device ]] || fail "Android device $device is not online."
droid=("$adb" -s "$device")
[[ $("${droid[@]}" shell getprop sys.boot_completed) == 1 ]] || fail "Android device $device has not finished booting."

# The Android watch owns a fixed local adb forward. Leave any existing session alone.
patch_port=tcp:39817
forwards=$("$adb" forward --list)
if awk -v port="$patch_port" '$2 == port {found = 1} END {exit !found}' <<< "$forwards"; then
	fail "adb already forwards $patch_port. Stop the existing Android watch first."
fi

tmp=$(mktemp -d)
project="$tmp/android_smoke_$$"
watch_log="$tmp/watch.log"
org=org.haxeon.ci
app_id="$org.${project##*/}"
watch_pid=
cleanup() {
	local status=$?
	if [[ -n "$watch_pid" ]]; then
		kill "$watch_pid" 2>/dev/null || true
		wait "$watch_pid" 2>/dev/null || true
	fi
	if (( status != 0 )) && [[ -f "$watch_log" ]]; then
		echo "Android watch log" >&2
		cat "$watch_log" >&2
		echo "Android runtime and crash log" >&2
		"${droid[@]}" logcat -d -s Haxeon AndroidRuntime | tail -n 100 >&2 || true
	fi
	if [[ -n "$watch_pid" ]]; then
		"${droid[@]}" forward --remove "$patch_port" >/dev/null 2>&1 || true
		"${droid[@]}" uninstall "$app_id" >/dev/null 2>&1 || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for() {
	local seconds=$1 description=$2 deadline
	shift 2
	deadline=$((SECONDS + seconds))
	while (( SECONDS < deadline )); do
		kill -0 "$watch_pid" 2>/dev/null || fail "Android watch exited while waiting for $description."
		if "$@"; then
			return
		fi
		sleep 1
	done
	fail "Timed out waiting for $description."
}

app_started() {
	app_pid=$("${droid[@]}" shell pidof "$app_id") && [[ "$app_pid" =~ ^[0-9]+$ ]] &&
		"${droid[@]}" logcat -d --pid="$app_pid" -s Haxeon | grep -F 'initial app.main completed' >/dev/null &&
		"${droid[@]}" shell dumpsys gfxinfo "$app_id" | grep -E 'Total frames rendered: [1-9][0-9]*' >/dev/null
}

haxeon="$root/scripts/haxeon"
"$haxeon" create "$project" --platforms android --org "$org"
main="$project/src/Main.hx"
sed 's/Hello from /Live edit from /' "$main" > "$tmp/patch.hx"
cmp -s "$main" "$tmp/patch.hx" && fail "Could not find the template greeting to edit."
{
	echo 'var smokeRevision = 2;'
	sed 's/Sys.println("Live edit from /Sys.println(smokeRevision + ": Live edit from /' "$tmp/patch.hx"
} > "$tmp/reload.hx"

HL_STDOUT_FLUSH=1 "$haxeon" run --project "$project" --target android --device "$device" --jobs 4 --watch \
	> "$watch_log" 2>&1 &
watch_pid=$!
echo "Building and launching $app_id on $device"
wait_for 900 "the Android watcher to start" grep -Fq 'for edits; each is sent to' "$watch_log"
[[ -s "$project/build/android/app-debug.apk" ]] || fail "The Android build did not produce a debug APK."
wait_for 60 "the app to start and draw a frame" app_started
echo "ok: $app_id started and rendered a frame (PID $app_pid)"

mv "$tmp/patch.hx" "$main"
wait_for 120 "the device to apply the body patch" grep -Fq 'applied the patch; the device runs revision' "$watch_log"
grep -F 'applied the patch; the device runs revision' "$watch_log"
[[ $("${droid[@]}" shell pidof "$app_id") == "$app_pid" ]] || fail "The app process changed after the patch."

mv "$tmp/reload.hx" "$main"
wait_for 120 "the device to apply the structural reload" grep -Fq 'applied the reload; the device runs revision' "$watch_log"
grep -F 'applied the reload; the device runs revision' "$watch_log"
[[ $("${droid[@]}" shell pidof "$app_id") == "$app_pid" ]] || fail "The app process changed after the reload."
echo "ok: Android runner rendered, patched and reloaded in PID $app_pid"
