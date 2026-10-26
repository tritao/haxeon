#!/usr/bin/env bash
# NativeKit's trace sink: an app that starts NativeKitRuntime and draws frames records nk.wait and nk.frame spans, and
# the OS input it dequeues as input events with an age, in a profiler capture. Input comes from xdotool inside Xvfb,
# so the test is skipped where either is missing or the platform is not Linux.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
platform_dir="$repo_dir/packages/platform"

if [[ $(uname -s) != Linux ]] || ! command -v xvfb-run >/dev/null || ! command -v xdotool >/dev/null; then
	echo "SKIP NativeKit trace test (needs Linux, xvfb-run and xdotool)"
	exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src"

cat > "$scratch/src/TraceProbe.hx" <<'HAXE'
import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

class TraceProbe {
	static function main():Int {
		var runtime = NativeKitRuntime.start();
		if (!haxeon.ProfileNativeTrace.install("nativekit"))
			return 3;
		var options = new WindowOptions();
		options.set_width(400);
		options.set_height(300);
		options.set_title("trace probe");
		options.set_owner(WindowHandle.invalid());
		options.set_kind(WindowKind.Normal);
		var window = runtime.createWindow(options);
		var surfaceOptions = new SurfaceOptions();
		surfaceOptions.set_api(GraphicsApi.Opengl);
		surfaceOptions.set_flags(SurfaceFlags.ForwardCompatible);
		surfaceOptions.set_major_version(3);
		surfaceOptions.set_minor_version(3);
		surfaceOptions.set_width(400);
		surfaceOptions.set_height(300);
		var surface = window.createSurface(surfaceOptions);
		var frames = 0;
		var subscription = surface.onFrame(function(width, height) {
			frames++;
			// Keep requesting, as an animating UI does.
			NativeKit.nk_surface_request_frame(surface.nativeHandle());
		});
		NativeKit.nk_surface_set_frame_mode(surface.nativeHandle(), SurfaceFrameMode.OnDemand);
		NativeKit.nk_surface_request_frame(surface.nativeHandle());
		for (i in 0...300) {
			NativeKit.nk_wait_events_timeout(0.01);
			while (runtime.events.poll()) {}
		}
		Sys.println("frames=" + frames);
		subscription.dispose();
		surface.dispose();
		window.dispose();
		runtime.dispose();
		return 42;
	}
}
HAXE

cmake -S "$repo_dir/vendor/nativekit" -B "$scratch/nativekit" -GNinja -DCMAKE_BUILD_TYPE=Release -DNK_BUILD_SHARED=ON \
	-DNK_BUILD_EXAMPLES=OFF -DNK_BUILD_TESTS=OFF > "$scratch/nativekit-configure.log" 2>&1 || {
	cat "$scratch/nativekit-configure.log" >&2
	exit 1
}
cmake --build "$scratch/nativekit" > "$scratch/nativekit-build.log" 2>&1 || {
	tail -n 40 "$scratch/nativekit-build.log" >&2
	exit 1
}

(
	cd "$repo_dir"
	.tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler \
		--output="$scratch/probe.hl" \
		--entry=TraceProbe \
		--root="$scratch/src" \
		--root="$platform_dir/src" \
		--ffi-interface="$platform_dir/bindings/nativekit.hxi" \
		--ffi-projection="$platform_dir/bindings/nativekit.hxmap" \
		--ffi-interface="$platform_dir/bindings/nativekit-net.hxi" \
		--ffi-projection="$platform_dir/bindings/nativekit-net.hxmap" \
		--ffi-interface="$platform_dir/bindings/nativekit-vulkan.hxi" \
		--ffi-projection="$platform_dir/bindings/nativekit-vulkan.hxmap" \
		"$scratch/src/TraceProbe.hx" "$platform_dir"/src/haxeon/platform/*.hx
) > "$scratch/compile.log" 2>&1 || {
	cat "$scratch/compile.log" >&2
	exit 1
}

cat > "$scratch/session.sh" <<SESSION
#!/usr/bin/env bash
set -u
export LD_LIBRARY_PATH="$scratch/nativekit:$repo_dir/out:$repo_dir/.tools/hashlink"
port=\$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
"$repo_dir/.tools/hashlink/hl" --diagnostics "\$port" --diagnostics-wait "$scratch/probe.hl" > "$scratch/app.log" 2>&1 &
app=\$!
sleep 0.5
"$repo_dir/.tools/hashlink/hlprof-live" --sources sampling --connect-timeout 10 --output "$scratch/capture.hlpc" "\$port" > "$scratch/profiler.log" 2>&1 &
profiler=\$!
sleep 1.2
for i in \$(seq 1 40); do xdotool mousemove \$((50 + i * 5)) \$((60 + i * 3)); sleep 0.02; done
xdotool key a key b
wait \$app; status=\$?
wait \$profiler
exit \$status
SESSION
chmod +x "$scratch/session.sh"

status=0
timeout 120 xvfb-run -a "$scratch/session.sh" || status=$?
if [[ $status -ne 42 ]]; then
	cat "$scratch/app.log" "$scratch/profiler.log" >&2
	echo "NativeKit trace test: probe returned $status, expected 42" >&2
	exit 1
fi

"$repo_dir/.tools/hashlink/hlprof-live" export --format perfetto --output "$scratch/trace.json" "$scratch/capture.hlpc"
frames=$(sed -n 's/^frames=//p' "$scratch/app.log")
python3 - "$scratch/trace.json" "$frames" <<'PY'
import collections
import json
import sys

events = json.load(open(sys.argv[1]))
events = events["traceEvents"] if isinstance(events, dict) else events
drawn = int(sys.argv[2])
counts = collections.Counter((e.get("ph"), e.get("name")) for e in events)
waits = counts[("B", "nk.wait")]
frames = counts[("B", "nk.frame")]
moves = counts[("i", "input move")]
keys = counts[("i", "input key")]
ages = [e["args"]["ns"] for e in events if e.get("name") == "Input age"]
polled_moves = counts[("i", "input polled move")]
polled_keys = counts[("i", "input polled key")]
polled_ages = [e["args"]["ns"] for e in events if e.get("name") == "Input polled age"]

assert waits > 0, f"no nk.wait spans: {counts}"
assert drawn > 0, "the probe drew no frames"
assert frames == drawn, f"{frames} nk.frame spans for {drawn} drawn frames"
assert moves > 0, f"no input move events: {counts}"
assert keys > 0, f"no input key events: {counts}"
assert ages and all(0 <= age < 5_000_000_000 for age in ages), f"implausible input ages: {ages[:5]}"
assert polled_moves > 0 and polled_keys > 0, f"the host's polls of inputs were not recorded: {counts}"
assert polled_ages and all(0 <= age < 5_000_000_000 for age in polled_ages), f"implausible polled ages: {polled_ages[:5]}"
# An input is polled after NativeKit's handler had it, so it is older by then: none is younger than the youngest the handler
# saw. (Medians would not do: the polls see fewer inputs, as the queue merges moves, and the two differ by far less than
# the spread.)
assert min(polled_ages) >= min(ages), (min(polled_ages), min(ages))
position = next(e for e in events if e.get("name") == "input move")["args"]
assert position["a"] >= 0 and position["b"] >= 0, position
print(f"PASS: NativeKit's sink recorded {waits} waits, {frames} frames, {moves} moves and {keys} keys with input ages, and "
      f"{polled_moves} polled moves and {polled_keys} polled keys")
PY
